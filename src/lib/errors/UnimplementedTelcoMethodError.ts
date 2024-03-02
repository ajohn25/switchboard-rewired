import { Service } from '../types';

export class UnimplementedTelcoMethodError extends Error {
  constructor(service: Service, method: string) {
    super(`TelcoService '${service}' does not implement ${method}`);
  }
}

export default UnimplementedTelcoMethodError;
