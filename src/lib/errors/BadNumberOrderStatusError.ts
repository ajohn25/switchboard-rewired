import { Service } from '../types';

export class BadNumberOrderStatusError extends Error {
  public readonly service: Service;
  public readonly orderId: string;
  public readonly status: string;

  constructor(service: Service, orderId: string, status: string) {
    super(
      `${service} number order ${orderId} was not successful. Got status ${status}`
    );
    this.service = service;
    this.orderId = orderId;
    this.status = status;
  }
}
