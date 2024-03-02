import { DeliveryReportEvent } from '../../lib/types';

export type MessageDeliveredMock = (
  serviceId: string,
  messageId: string,
  eventType: DeliveryReportEvent,
  generatedAt: string,
  originalCreatedAt: string
) => any;

export interface TelcoMock {
  mockMessageDelivered: MessageDeliveredMock;
}
