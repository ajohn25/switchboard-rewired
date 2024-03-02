import { Service } from '../types';

export class NoAvailableNumbersError extends Error {
  public readonly service: Service;
  public readonly areaCode: string;

  constructor(service: Service, areaCode: string) {
    super(`No ${service} numbers available in ${areaCode}`);
    this.service = service;
    this.areaCode = areaCode;
  }
}
