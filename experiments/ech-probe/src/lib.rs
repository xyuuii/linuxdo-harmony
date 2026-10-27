//! Isolated, credential-free TLS/ECH experiment. Not the application's transport.
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use hickory_proto::{
    op::{Message, Query, ResponseCode},
    rr::{
        Name, RData, RecordType,
        rdata::svcb::{SvcParamKey, SvcParamValue},
    },
};
use rustls::{
    ClientConfig, ClientConnection, RootCertStore, Stream,
    client::{EchConfig, EchMode, EchStatus},
    crypto::aws_lc_rs,
    pki_types::{EchConfigListBytes, ServerName},
};
use serde_json::{Value, json};
use std::{
    error::Error,
    ffi::{CStr, CString, c_char},
    fs,
    io::{self, Read, Write},
    net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
const MAX_HTTP: usize = 1024 * 1024;
const MAX_DNS: usize = 65535;
static CANCELLED: AtomicBool = AtomicBool::new(false);

struct DeadlineSocket {
    socket: TcpStream,
    deadline: Instant,
}
impl DeadlineSocket {
    fn remaining(&self) -> io::Result<Duration> {
        if CANCELLED.load(Ordering::Relaxed) {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "probe cancelled",
            ));
        }
        let remaining = self.deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "request deadline"));
        }
        Ok(remaining.min(Duration::from_secs(6)))
    }
}
impl Read for DeadlineSocket {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        self.socket.set_read_timeout(Some(self.remaining()?))?;
        self.socket.read(out)
    }
}
impl Write for DeadlineSocket {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        self.socket.set_write_timeout(Some(self.remaining()?))?;
        self.socket.write(data)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.socket.flush()
    }
}

struct HttpReply {
    status: u16,
    body: Vec<u8>,
    ech: EchStatus,
    tls: String,
    mitigated: bool,
}

fn tls_config(ech: Option<&[u8]>) -> Result<ClientConfig> {
    let builder = ClientConfig::builder_with_provider(aws_lc_rs::default_provider().into());
    let builder = match ech {
        Some(bytes) => builder.with_ech(EchMode::from(EchConfig::new(
            EchConfigListBytes::from(bytes.to_vec()),
            aws_lc_rs::hpke::ALL_SUPPORTED_SUITES,
        )?))?,
        None => builder.with_protocol_versions(&[&rustls::version::TLS13])?,
    };
    let roots = RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    let mut config = builder.with_root_certificates(roots).with_no_client_auth();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(config)
}

fn decode_http(wire: &[u8]) -> Result<(u16, Vec<u8>, bool)> {
    let mut headers = [httparse::EMPTY_HEADER; 64];
    let mut response = httparse::Response::new(&mut headers);
    let offset = match response.parse(wire)? {
        httparse::Status::Complete(offset) => offset,
        httparse::Status::Partial => return Err("incomplete HTTP headers".into()),
    };
    let status = response.code.ok_or("missing HTTP status")?;
    let mut length = None;
    let mut chunked = false;
    let mut mitigated = false;
    for header in response.headers {
        let value = std::str::from_utf8(header.value)?.trim();
        if header.name.eq_ignore_ascii_case("content-length") {
            length = Some(value.parse::<usize>()?);
        }
        if header.name.eq_ignore_ascii_case("transfer-encoding") {
            if !value.eq_ignore_ascii_case("chunked") {
                return Err("unsupported transfer encoding".into());
            }
            chunked = true;
        }
        if header.name.eq_ignore_ascii_case("cf-mitigated") {
            mitigated = value.eq_ignore_ascii_case("challenge");
        }
    }
    let payload = &wire[offset..];
    let body = if chunked {
        let mut body = Vec::new();
        let mut decoder = chunked_transfer::Decoder::new(payload);
        decoder
            .by_ref()
            .take((MAX_HTTP + 1) as u64)
            .read_to_end(&mut body)?;
        if decoder.remaining_chunks_size().is_some() {
            return Err("incomplete HTTP chunk".into());
        }
        body
    } else if let Some(length) = length {
        if length > MAX_HTTP || length > payload.len() {
            return Err("incomplete or oversized HTTP body".into());
        }
        payload[..length].to_vec()
    } else {
        payload.to_vec()
    };
    if body.len() > MAX_HTTP {
        return Err("HTTP body exceeds limit".into());
    }
    Ok((status, body, mitigated))
}

fn http_get(
    host: &str,
    ip: IpAddr,
    path: &str,
    ech: Option<&[u8]>,
    dns: bool,
    user_agent: Option<&str>,
) -> Result<HttpReply> {
    let config = tls_config(ech)?;
    let mut conn = ClientConnection::new(Arc::new(config), ServerName::try_from(host.to_owned())?)?;
    let deadline = Instant::now() + Duration::from_secs(14);
    let socket = TcpStream::connect_timeout(&SocketAddr::new(ip, 443), Duration::from_secs(5))?;
    let mut socket = DeadlineSocket { socket, deadline };
    while conn.is_handshaking() {
        conn.complete_io(&mut socket)?;
    }
    let status = conn.ech_status();
    // No GREASE or cleartext fallback is accepted as ECH success. Do not send HTTP on rejection.
    if ech.is_some() && status != EchStatus::Accepted {
        return Err(format!("ECH not accepted: {status:?}").into());
    }
    let tls = format!(
        "{:?}",
        conn.protocol_version().ok_or("TLS version unavailable")?
    );
    let accept = if dns {
        "application/dns-message"
    } else {
        "application/json,text/plain"
    };
    let mut request = format!(
        "GET {path} HTTP/1.1\r\nHost: {host}\r\nAccept: {accept}\r\nAccept-Encoding: identity\r\nConnection: close\r\n"
    );
    if let Some(user_agent) = user_agent {
        request.push_str(&format!(
            "User-Agent: {user_agent}\r\nAccept-Language: zh-CN,zh;q=0.9,en;q=0.8\r\n"
        ));
        if host == "linux.do" {
            request.push_str("X-Requested-With: XMLHttpRequest\r\nReferer: https://linux.do/\r\n");
        }
    }
    request.push_str("\r\n");
    let mut stream = Stream::new(&mut conn, &mut socket);
    stream.write_all(request.as_bytes())?;
    let mut wire = Vec::new();
    match stream.take((MAX_HTTP + 1) as u64).read_to_end(&mut wire) {
        Ok(_) => {}
        // Some HTTP/1 servers close TCP without TLS close_notify. Framing is validated below.
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof && !wire.is_empty() => {}
        Err(e) => return Err(e.into()),
    }
    if wire.len() > MAX_HTTP {
        return Err("response exceeds limit".into());
    }
    let (http_status, body, mitigated) = decode_http(&wire)?;
    Ok(HttpReply {
        status: http_status,
        body,
        ech: status,
        tls,
        mitigated,
    })
}

fn resolver(name: &str) -> Result<(&'static str, IpAddr, &'static str)> {
    let (host, ip, path) = match name {
        "cloudflare" => ("cloudflare-dns.com", Some("1.1.1.1"), "/dns-query"),
        "aliyun" => ("dns.alidns.com", Some("223.5.5.5"), "/dns-query"),
        "kudo" => ("kudo.ddd.oaifree.com", None, "/query-dns"),
        "edge" => ("edge.1molchuan.top", None, "/linuxdo"),
        _ => return Err("resolver is not allowlisted".into()),
    };
    let ip = match ip {
        Some(ip) => ip.parse()?,
        None => (host, 443)
            .to_socket_addrs()?
            .find(|a| a.is_ipv4())
            .ok_or("resolver has no IPv4 address")?
            .ip(),
    };
    Ok((host, ip, path))
}

fn make_dns_query(host: &str, kind: RecordType) -> Result<Message> {
    let mut query = Message::query();
    query.metadata.id = 0; // RFC 8484 recommends a zero DNS ID for cacheable HTTP requests.
    let name = Name::from_ascii(format!("{}.", host.trim_end_matches('.')))?;
    query.add_query(Query::query(name, kind));
    query.metadata.recursion_desired = true;
    Ok(query)
}

fn dns_query(host: &str, kind: RecordType, provider: &str) -> Result<Message> {
    let query = make_dns_query(host, kind)?;
    let name = query.queries[0].name();
    let encoded = URL_SAFE_NO_PAD.encode(query.to_vec()?);
    let (resolver_host, resolver_ip, resolver_path) = resolver(provider)?;
    let response = http_get(
        resolver_host,
        resolver_ip,
        &format!("{resolver_path}?dns={encoded}"),
        None,
        true,
        None,
    )?;
    if response.status != 200 || response.body.len() > MAX_DNS {
        return Err(format!("DoH HTTP {}", response.status).into());
    }
    let answer = Message::from_vec(&response.body)?;
    if answer.metadata.id != query.metadata.id
        || answer.metadata.response_code != ResponseCode::NoError
        || answer.queries.len() != 1
        || answer.queries[0].name() != name
        || answer.queries[0].query_type() != kind
    {
        return Err("invalid DoH response question/status".into());
    }
    Ok(answer)
}

fn lookup(host: &str, provider: &str) -> Result<(Vec<IpAddr>, Vec<u8>)> {
    let https = dns_query(host, RecordType::HTTPS, provider)?;
    let mut configs = Vec::new();
    for record in &https.answers {
        if let RData::HTTPS(https) = &record.data {
            for (key, value) in &https.0.svc_params {
                if let (SvcParamKey::EchConfigList, SvcParamValue::EchConfigList(ech)) =
                    (key, value)
                {
                    configs = ech.0.clone();
                    break;
                }
            }
        }
    }
    let addresses = dns_query(host, RecordType::A, provider)?
        .answers
        .iter()
        .filter_map(|r| {
            if let RData::A(address) = &r.data {
                Some(IpAddr::V4(address.0))
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    if addresses.is_empty() {
        return Err("DoH returned no IPv4 addresses".into());
    }
    if configs.is_empty() {
        return Err("DoH HTTPS response has no ECH configuration; no fallback".into());
    }
    Ok((addresses, configs))
}

fn read_seed(path: &str, host: &str) -> Result<(Vec<IpAddr>, Vec<u8>)> {
    let bytes = fs::read(path)?;
    if bytes.len() > 65536 {
        return Err("seed exceeds limit".into());
    }
    seed_data(&serde_json::from_slice(&bytes)?, host)
}

fn seed_data(seed: &Value, host: &str) -> Result<(Vec<IpAddr>, Vec<u8>)> {
    if seed["host"].as_str() != Some(host) {
        return Err("seed host mismatch".into());
    }
    let age = SystemTime::now()
        .duration_since(UNIX_EPOCH)?
        .as_secs()
        .abs_diff(
            seed["fetched_at"]
                .as_u64()
                .ok_or("seed timestamp missing")?,
        );
    let ttl = seed["ttl"].as_u64().ok_or("seed TTL missing")?.min(600);
    if age > ttl {
        return Err("seed expired; fetch fresh authenticated DoH data".into());
    }
    let addresses = seed["addresses"]
        .as_array()
        .ok_or("seed addresses missing")?
        .iter()
        .map(|v| Ok(v.as_str().ok_or("invalid address")?.parse()?))
        .collect::<Result<Vec<IpAddr>>>()?;
    let ech = STANDARD.decode(
        seed["ech_config_base64"]
            .as_str()
            .ok_or("seed ECH missing")?,
    )?;
    if addresses.is_empty() || ech.is_empty() {
        return Err("seed is empty".into());
    }
    Ok((addresses, ech))
}

fn summary(reply: &HttpReply, host: &str, path: &str) -> Value {
    let body = String::from_utf8_lossy(&reply.body);
    let mut trace = serde_json::Map::new();
    if path == "/cdn-cgi/trace" {
        for line in body.lines() {
            if let Some((key, value)) = line.split_once('=') {
                if ["h", "tls", "sni"].contains(&key) {
                    trace.insert(key.into(), value.into());
                }
            }
        }
    }
    let confirmed = reply.ech == EchStatus::Accepted
        && reply.status == 200
        && trace.get("h").and_then(Value::as_str) == Some(host)
        && trace.get("sni").and_then(Value::as_str) == Some("encrypted");
    let topic_count = if path == "/latest.json" {
        serde_json::from_slice::<Value>(&reply.body)
            .ok()
            .and_then(|v| v["topic_list"]["topics"].as_array().map(Vec::len))
    } else {
        None
    };
    json!({"tls": reply.tls, "ech_status": format!("{:?}", reply.ech), "certificate_verified": true,
        "http_status": reply.status, "cf_challenge": reply.mitigated, "trace": trace,
        "ech_trace_confirmed": confirmed, "public_topic_count": topic_count})
}

pub fn collect(args: &[String], seed: Option<&Value>) -> Result<Vec<Value>> {
    if args.is_empty() {
        return Err("usage: linuxdo-ech-probe HOST cloudflare|aliyun|--seed=FILE [both|ech|plain] [trace|latest]".into());
    }
    let host = &args[0];
    if !["linux.do", "crypto.cloudflare.com"].contains(&host.as_str()) {
        return Err("probe target is not allowlisted".into());
    }
    let provider = args.get(1).map(String::as_str).unwrap_or("cloudflare");
    let mode = args.get(2).map(String::as_str).unwrap_or("both");
    if !["both", "ech", "plain"].contains(&mode) {
        return Err("invalid probe mode".into());
    }
    let path = match args.get(3).map(String::as_str).unwrap_or("trace") {
        "trace" => "/cdn-cgi/trace",
        "latest" if host == "linux.do" => "/latest.json",
        _ => return Err("path is not allowlisted".into()),
    };
    let user_agent = args.get(4).map(String::as_str);
    if user_agent.is_some_and(|ua| ua.len() > 1024 || ua.contains(['\r', '\n'])) {
        return Err("invalid user agent".into());
    }
    let (addresses, ech) = if provider == "seed" {
        seed_data(seed.ok_or("inline seed missing")?, host)?
    } else if let Some(path) = provider.strip_prefix("--seed=") {
        read_seed(path, host)?
    } else {
        lookup(host, provider)?
    };
    let mut results = vec![
        json!({"stage":"dns", "host":host, "provider":provider.split('=').next().unwrap_or(provider),
        "addresses":addresses, "ech_config_bytes":ech.len(), "credentials":false}),
    ];
    for ip in addresses.iter().take(2) {
        for use_ech in [false, true] {
            if CANCELLED.load(Ordering::Relaxed) {
                return Err("probe cancelled".into());
            }
            if (mode == "ech" && !use_ech) || (mode == "plain" && use_ech) {
                continue;
            }
            let start = Instant::now();
            let result = match http_get(
                host,
                *ip,
                path,
                use_ech.then_some(ech.as_slice()),
                false,
                user_agent,
            ) {
                Ok(reply) => summary(&reply, host, path),
                Err(error) => json!({"error":error.to_string(), "ech_trace_confirmed":false}),
            };
            results.push(json!({"stage":"request", "host":host, "peer_ip":ip, "mode":if use_ech {"ech-required"} else {"plain-control"},
                "path":path, "elapsed_ms":start.elapsed().as_millis(), "result":result}));
        }
    }
    Ok(results)
}

pub fn probe_json(input: &str) -> String {
    let run = || -> Result<Vec<Value>> {
        if input.len() > 65536 {
            return Err("probe input exceeds limit".into());
        }
        let input: Value = serde_json::from_str(input)?;
        let provider = input["provider"].as_str().ok_or("provider missing")?;
        if !["cloudflare", "aliyun", "kudo", "edge", "seed"].contains(&provider) {
            return Err("provider is not allowlisted".into());
        }
        let mut args = vec![
            input["host"].as_str().ok_or("host missing")?.to_owned(),
            provider.to_owned(),
            input["mode"].as_str().unwrap_or("both").to_owned(),
            input["path"].as_str().unwrap_or("trace").to_owned(),
        ];
        if let Some(ua) = input["user_agent"].as_str() {
            args.push(ua.to_owned());
        }
        let seed = input
            .get("seed_json")
            .and_then(Value::as_str)
            .map(serde_json::from_str::<Value>)
            .transpose()?;
        collect(&args, seed.as_ref())
    };
    match run() {
        Ok(results) => json!(results).to_string(),
        Err(error) => json!([{"stage":"fatal","error":error.to_string()}]).to_string(),
    }
}

/// Called only by the signed prototype's native wrapper, never exposed to Web content.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ech_probe_run(input: *const c_char) -> *mut c_char {
    let output = std::panic::catch_unwind(|| {
        if input.is_null() {
            return "[{\"stage\":\"fatal\",\"error\":\"null input\"}]".to_owned();
        }
        match unsafe { CStr::from_ptr(input) }.to_str() {
            Ok(input) => probe_json(input),
            Err(_) => "[{\"stage\":\"fatal\",\"error\":\"invalid UTF-8\"}]".to_owned(),
        }
    })
    .unwrap_or_else(|_| "[{\"stage\":\"fatal\",\"error\":\"native panic contained\"}]".to_owned());
    CString::new(output)
        .expect("JSON has no literal NUL")
        .into_raw()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ech_probe_free(output: *mut c_char) {
    if !output.is_null() {
        drop(unsafe { CString::from_raw(output) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ech_probe_cancel() {
    CANCELLED.store(true, Ordering::Relaxed);
}

#[unsafe(no_mangle)]
pub extern "C" fn ech_probe_prepare() {
    CANCELLED.store(false, Ordering::Relaxed);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dns_question_comparison_survives_the_wire_round_trip() {
        let query = make_dns_query("linux.do", RecordType::HTTPS).unwrap();
        let decoded = Message::from_vec(&query.to_vec().unwrap()).unwrap();
        assert_eq!(query.queries[0], decoded.queries[0]);
        assert!(query.queries[0].name().is_fqdn());
    }
    #[test]
    fn incomplete_http_and_chunks_are_rejected() {
        assert!(decode_http(b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nshort").is_err());
        assert!(
            decode_http(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nx").is_err()
        );
        assert_eq!(
            decode_http(
                b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
            )
            .unwrap()
            .1,
            b"abc"
        );
    }
    #[test]
    fn grease_and_plaintext_cannot_count_as_ech_and_no_source_ip_is_output() {
        for ech in [
            EchStatus::Grease,
            EchStatus::NotOffered,
            EchStatus::Accepted,
        ] {
            let reply = HttpReply {
                status: 200,
                body: b"h=linux.do\nsni=encrypted\ntls=TLSv1.3\nip=192.0.2.1\n".to_vec(),
                ech,
                tls: "TLSv1_3".into(),
                mitigated: false,
            };
            let result = summary(&reply, "linux.do", "/cdn-cgi/trace");
            assert_eq!(result["ech_trace_confirmed"], ech == EchStatus::Accepted);
            assert!(!result.to_string().contains("192.0.2.1"));
        }
    }
    #[test]
    fn stale_or_wrong_host_seeds_and_unapproved_native_inputs_are_rejected() {
        let seed = json!({"host":"linux.do", "fetched_at":1, "ttl":300,
            "addresses":["172.66.166.61"], "ech_config_base64":"AAECAw=="});
        assert!(seed_data(&seed, "linux.do").is_err());
        assert!(seed_data(&seed, "crypto.cloudflare.com").is_err());
        for input in [
            r#"{"host":"evil.test","provider":"seed"}"#,
            r#"{"host":"linux.do","provider":"--seed=/private/file"}"#,
            r#"{"host":"linux.do","provider":"seed","path":"/session.json"}"#,
        ] {
            let output: Value = serde_json::from_str(&probe_json(input)).unwrap();
            assert_eq!(output[0]["stage"], "fatal");
        }
        assert!(tls_config(Some(&[0, 1, 2])).is_err());
        let input = json!({"host":"linux.do", "provider":"kudo", "user_agent":"fixture\r\nCookie: fixture"});
        let output: Value = serde_json::from_str(&probe_json(&input.to_string())).unwrap();
        assert_eq!(output[0]["stage"], "fatal");
    }
}
