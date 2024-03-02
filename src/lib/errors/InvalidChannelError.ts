export class InvalidChannelError extends Error {
  public readonly channel: string;

  constructor(channel: string) {
    super(`Invalid traffic channel ${channel}`);
    this.channel = channel;
  }
}
