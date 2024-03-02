import express from 'express';
import { CheckIntegrityConstraintViolationError } from 'slonik';

import { pool, sql } from '../db';
import { presistIncomingMessage } from '../lib/inbound';
import { getTelcoClient } from '../lib/services';
import { SendingAccount } from '../lib/types';
import { errToObj, logger } from '../logger';

const app = express();

app.post('/:sendingAccount', async (req, res) => {
  const sendingAccountId = req.params.sendingAccount;
  let sendingAccount: SendingAccount;
  try {
    sendingAccount = await pool.one<SendingAccount>(
      sql`select * from sms.sending_accounts_as_json where id = ${sendingAccountId}`
    );
  } catch {
    return res
      .status(404)
      .json({ error: 'No matching profile for incoming delivery report' });
  }

  try {
    const telcoClient = getTelcoClient(sendingAccount);
    const { message, httpResponseHandler } =
      await telcoClient.processInboundMessage({ req });
    const messageId = await presistIncomingMessage(message);
    await httpResponseHandler(messageId, res);
  } catch (err: any) {
    if (
      err instanceof CheckIntegrityConstraintViolationError &&
      err.constraint === 'e164'
    ) {
      // Inbound message is not from a valid long-code number (e.g. short-code spam) - ignore it
      return res.sendStatus(200);
    }

    const errContext = {
      ...errToObj(err),
      sendingAccountId,
      body: req.body,
    };

    if (err.severity === 'ERROR' && err.code === 'SI000') {
      // Inbound message was sent to a TN that is not active
      logger.info(errContext);
      return res.sendStatus(200);
    }

    logger.error(`Error handling inbound message: `, errContext);
    return res.sendStatus(500);
  }
});

export default app;
