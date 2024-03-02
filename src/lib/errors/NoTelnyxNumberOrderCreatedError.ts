export class NoTelnyxNumberOrderCreatedError extends Error {
  public service: string;
  public areaCode: string;
  constructor(service: string, areaCode: string) {
    super(
      `telnyx_purchase_number_no_order_created - service ${service} - areaCode ${areaCode}`
    );
    this.service = service;
    this.areaCode = areaCode;
  }
}
