import config from '../../config';
import telnyx from './telnyx';

const service = telnyx;

const mockResults: { [key: string]: any } = {
  '+12147010869': {
    carrier_name: 'CELLCO PARTNERSHIP DBA VERIZON WIRELESS - TX',
    number: '+12147010869',
    ocn: '6506',
    phone_type: 'mobile',
    ported_date: '',
    ported_status: 'N',
    spid: '6006',
  },
  '+18459430872': {
    carrier_name: 'Verizon Wireless:6006 - SVR/2',
    number: '+18459430872',
    ocn: '6959',
    phone_type: 'mobile',
    ported_date: '20040902064600',
    ported_status: 'Y',
    spid: '6006',
  },
};

export async function lookup(phoneNumber: string) {
  if (config.isTest || config.dryRunMode) {
    return mockResults[phoneNumber];
  }

  return service.lookup(phoneNumber);
}
