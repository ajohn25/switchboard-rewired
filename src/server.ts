import app from './app';
import config from './config';
import { logger } from './logger';
import worker from './worker';
const { port, mode } = config;

process.on('unhandledRejection', (err) => {
  logger.error('Unhandled rejection: ', err);
  process.exit(1);
});

logger.info(`Starting with mode ${mode}`);

if (mode === 'SERVER' || mode === 'DUAL') {
  app.listen(port, () => {
    logger.info(`Server listening on localhost:${port}`);
  });
}

if (mode === 'WORKER' || mode === 'DUAL') {
  worker.start(config.databaseUrl).then(() => {
    logger.info(`Worker started`);
  });
}
