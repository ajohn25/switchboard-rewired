export class NoFallbackAreaCodeError extends Error {
  constructor(service: string, areaCode: string) {
    super(`Could not find fallback area code for ${areaCode} on ${service}`);
  }
}
