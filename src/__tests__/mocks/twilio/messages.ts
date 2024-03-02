import { EVENT_TYPE_MAP } from '../../../lib/services/twilio';
import {
  DeliveryReportEvent,
  TwilioDeliveryReportRequestBody,
  TwilioDeliveryReportStatus,
} from '../../../lib/types';
import { MessageDeliveredMock } from '../types';

export const mockTwilioMessageDelivered: MessageDeliveredMock = (
  _messageId: string,
  serviceId: string,
  eventType: DeliveryReportEvent,
  _generatedAt: string,
  _originalCreatedAt: string
) => {
  const twilioEvent = Object.entries(EVENT_TYPE_MAP).find(
    ([_, val]) => val === eventType
  )![0] as TwilioDeliveryReportStatus;

  const body: TwilioDeliveryReportRequestBody = {
    ErrorCode: undefined,
    SmsSid: serviceId,
    SmsStatus: twilioEvent,
    MessageStatus: twilioEvent,
  };
  return body;
};
