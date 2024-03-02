import cryptr from 'cryptr';

import config from '../config';

export const crypt = new cryptr(config.applicationSecret);
