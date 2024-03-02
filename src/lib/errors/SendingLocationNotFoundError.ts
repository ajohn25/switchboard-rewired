export class SendingLocationNotFoundError extends Error {
  constructor() {
    super(`Could not find sending location`);
  }
}
