import { Service } from '../types';

export class InvalidFromNumberError extends Error {
  public readonly service: Service;
  public readonly phoneNumber: string;

  constructor(service: Service, phoneNumber: string) {
    super(`Invalid ${service} from number ${phoneNumber}`);
    this.service = service;
    this.phoneNumber = phoneNumber;
  }
}
