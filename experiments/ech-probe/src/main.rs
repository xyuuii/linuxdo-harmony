fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    match ech_probe_core::collect(&args, None) {
        Ok(results) => {
            for result in results {
                println!("{result}");
            }
        }
        Err(error) => {
            eprintln!(
                "{}",
                serde_json::json!({"stage":"fatal","error":error.to_string()})
            );
            std::process::exit(1);
        }
    }
}
