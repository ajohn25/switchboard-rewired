import { MessageDeliveredMock } from '../types';

export const mockTelnyxMessageDelivered: MessageDeliveredMock = (
  _messageId: string,
  serviceId: string,
  eventType: string,
  generatedAt: string,
  _originalCreatedAt: string
) => {
  const body = {
    data: {
      event_type: 'message.finalized',
      id: '4ee8c3a6-4995-4309-a3c6-38e3db9ea4be',
      occurred_at: generatedAt,
      payload: {
        completed_at: generatedAt,
        cost: null,
        direction: 'outbound',
        encoding: 'GSM-7',
        errors: [],
        from: {
          carrier: 'T-Mobile USA',
          line_type: 'Wireless',
          phone_number: '+13125000000',
          status: 'webhook_delivered',
        },
        id: serviceId,
        media: [],
        messaging_profile_id: '83d2343b-553f-4c5f-b8c8-fd27004f94bf',
        organization_id: '9d76d591-1b7d-405d-8c64-1320ee070245',
        parts: 1,
        received_at: generatedAt,
        record_type: 'message',
        sent_at: generatedAt,
        tags: [],
        text: 'Hello there!',
        to: [
          {
            carrier: 'T-MOBILE USA, INC.',
            line_type: 'Wireless',
            phone_number: '+13125000000',
            status: eventType,
          },
        ],
        type: 'SMS',
        valid_until: '2019-12-09T22:32:13.552+00:00',
        webhook_failover_url: '',
        webhook_url: 'http://webhook.site/af3a92e7-e150-442c-9fe6-61658ce26b1a',
      },
      record_type: 'event',
    },
    meta: {
      attempt: 1,
      delivered_to: 'http://webhook.site/af3a92e7-e150-442c-9fe6-61658ce26b1a',
    },
  };
  return body;
};
