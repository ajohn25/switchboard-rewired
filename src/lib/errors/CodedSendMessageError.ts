import { SwitchboardErrorCodes } from '../types';

export class CodedSendMessageError extends Error {
  public readonly errorCode: SwitchboardErrorCodes;

  constructor(errorCode: SwitchboardErrorCodes) {
    super(`Failed to send message with error code ${errorCode}`);
    this.errorCode = errorCode;
  }
}
