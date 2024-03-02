import { Service } from '../types';

export class InvalidProfileConfigurationError extends Error {
  public readonly service: Service;
  public readonly sendingAccountId: string;
  public readonly error: string;

  constructor(service: Service, sendingAccountId: string, error: string) {
    super(`${service} sending account (${sendingAccountId}): ${error}`);
    this.service = service;
    this.sendingAccountId = sendingAccountId;
    this.error = error;
  }
}
