import express from 'express';

import { logger } from '../logger';

const app = express();

app.post('/orders/:sendingAccount', async (req, res) => {
  const { notification } = req.body;
  logger.debug('Got Bandwidth order notification', { notification });
  return res.sendStatus(200);
});

app.post('/disconnects/:sendingAccount', async (req, res) => {
  // There's nothing to be done here - we've already marked the number as sold :/
  const { notification } = req.body;
  logger.debug('Got Bandwidth disconnect notification', { notification });
  res.sendStatus(500);
});

export default app;
