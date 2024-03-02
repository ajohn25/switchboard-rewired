import { EVENT_TYPE_MAP } from '../../../lib/services/bandwidth/bandwidth-base';
import { DeliveryReportEvent } from '../../../lib/types';
import { MessageDeliveredMock } from '../types';

export const mockBandwidthMessageDelivered: MessageDeliveredMock = (
  messageId: string,
  serviceId: string,
  eventType: DeliveryReportEvent,
  generatedAt: string,
  originalCreatedAt: string
) => {
  const [bandwidthEvent] = Object.entries(EVENT_TYPE_MAP).find(
    ([_, val]) => val === eventType
  )!;

  const body = [
    {
      type: bandwidthEvent,
      time: generatedAt,
      description: 'ok',
      to: '+12345678902',
      message: {
        id: serviceId,
        time: generatedAt,
        to: ['+12345678902'],
        from: '+12345678901',
        text: '',
        applicationId: '93de2206-9669-4e07-948d-329f4b722ee2',
        owner: '+12345678902',
        direction: 'out',
        segmentCount: 1,
        tag: `v1|${messageId}|${originalCreatedAt}`,
      },
    },
  ];
  return body;
};
