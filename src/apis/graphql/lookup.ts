import pgSimplifyInflector from '@graphile-contrib/pg-simplify-inflector';
import express from 'express';
import { postgraphile } from 'postgraphile';
import config from '../../config';
import { auth, GraphQlAuthenticatedRequest } from '../../lib/auth';
import AddPhoneNumbersToRequest from './AddPhoneNumbersToRequest';
import PhoneNumberDomain from './PhoneNumberDomain';

const app = express();

// Sets req.auth
app.use(auth.graphql);

const instance = postgraphile(config.databaseUrl, 'lookup', {
  appendPlugins: [
    pgSimplifyInflector,
    AddPhoneNumbersToRequest,
    PhoneNumberDomain,
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
