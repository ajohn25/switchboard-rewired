import pgSimplifyInflector from '@graphile-contrib/pg-simplify-inflector';
import express from 'express';
import { postgraphile } from 'postgraphile';

import config from '../../config';
import { auth, GraphQlAuthenticatedRequest } from '../../lib/auth';
import PhoneNumberDomain from './PhoneNumberDomain';
import ProvisionSendingLocations from './ProvisionSendingLocations';

const app = express();

// Sets req.auth
app.use(auth.graphql);

const instance = postgraphile(config.databaseUrl, 'sms', {
  appendPlugins: [
    pgSimplifyInflector,
    PhoneNumberDomain,
    ProvisionSendingLocations,
  ],
  disableQueryLog: config.isProduction,
  enhanceGraphiql: config.isDev,
  graphiql: config.isDev,
  graphiqlRoute: '/graphiql',
  graphqlRoute: '/graphql',
  ignoreRBAC: false,
  pgSettings: async (req: GraphQlAuthenticatedRequest) => {
    return req.auth;
  },
});

app.use(instance);

export default app;
