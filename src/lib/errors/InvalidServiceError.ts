export class InvalidServiceError extends Error {
  public readonly service: string;

  constructor(service: string) {
    super(`Invalid telco service ${service}`);
    this.service = service;
  }
}
