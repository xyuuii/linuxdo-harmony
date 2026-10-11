const LOGIN_HOSTS: string[] = ['linux.do', 'connect.linux.do', 'github.com', 'www.github.com',
  'accounts.google.com', 'discord.com', 'discordapp.com', 'appleid.apple.com'];

/** Navigation permissions are separate from the forum API / native bridge origin. */
export function loginOrigin(value: string): string {
  if (value.length > 16384 || /[\\\u0000-\u0020\u007F]/.test(value)) { return ''; }
  const match: RegExpMatchArray | null = value.match(/^https:\/\/([a-zA-Z0-9.-]+)(?::([0-9]+))?(?:[/?#]|$)/i);
  if (match === null || (match[2] !== undefined && match[2] !== '443')) { return ''; }
  const host: string = match[1].toLowerCase();
  return LOGIN_HOSTS.includes(host) ? `https://${host}` : '';
}

export function allowedLoginNavigation(value: string, allowBlank: boolean = false): boolean {
  return (allowBlank && (value === '' || value === 'about:blank')) || loginOrigin(value).length > 0;
}

export function loginPageTitle(value: string): string {
  const origin: string = loginOrigin(value);
  if (origin === 'https://github.com' || origin === 'https://www.github.com') { return 'GitHub 认证'; }
  if (origin === 'https://accounts.google.com') { return 'Google 认证'; }
  if (origin === 'https://discord.com' || origin === 'https://discordapp.com') { return 'Discord 认证'; }
  if (origin === 'https://appleid.apple.com') { return 'Apple 认证'; }
  return 'LINUX DO 登录与验证';
}
