import expressWinston from 'express-winston';
import { StatsD } from 'hot-shots';
import winston from 'winston';

import config from './config';

const loggerConfig = {
  format: config.isProduction
    ? winston.format.combine(winston.format.timestamp(), winston.format.json())
    : winston.format.combine(
        winston.format.colorize(),
        winston.format.simple()
      ),
  transports: [new winston.transports.Console({ level: config.logLevel })],
};

export const logger = winston.createLogger(loggerConfig);
export const expressLogger = expressWinston.logger(loggerConfig);
export const expressErrorLogger = expressWinston.errorLogger(loggerConfig);

/**
 * Convert an Error instance to a plain object, including all its non-iterable properties.
 * @param err Error to convert to Object
 * @returns Object representation of the error
 */
export const errToObj = (err: any): any =>
  Object.getOwnPropertyNames(err).reduce<Record<string, any>>((acc, name) => {
    acc[name] = err[name];
    return acc;
  }, {});

export const statsd =
  config.ddAgentHost && config.ddDogstatsdPort
    ? new StatsD({
        globalTags: config.ddTags,
        host: config.ddAgentHost,
        port: config.ddDogstatsdPort,
      })
    : undefined;

export const writeHistogram = (
  name: string,
  runtime: number,
  tags: string[]
) => {
  if (statsd !== undefined) {
    try {
      statsd.histogram(name, runtime, tags);
    } catch (ex) {
      logger.error(`Error posting ${name}`, ex);
    }
  }
};
