import { Service } from '../types';

export class BadNumberStatusError extends Error {
  public readonly service: Service;
  public readonly phoneNumber: string;
  public readonly status: string;

  constructor(service: Service, phoneNumber: string, status: string) {
    super(
      `${service} number ${phoneNumber} was not successful. Got status ${status}`
    );
    this.service = service;
    this.phoneNumber = phoneNumber;
    this.status = status;
  }
}
