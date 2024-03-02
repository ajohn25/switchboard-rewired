import faker from 'faker';
import { createPool, DatabasePool, sql } from 'slonik';
import superagentGraphql from 'superagent-graphql';
import supertest from 'supertest';
import app from '../../app';
import config from '../../config';

const ql = superagentGraphql;

const client1Name = `${faker.name.findName()} ${faker.random.word()}`;
const client2Name = `${faker.name.findName()} ${faker.random.word()}`;

const knownPhoneOne = '+12147010869';
const knownPhoneTwo = '+18459430872';

describe('request workflow', () => {
  let pool: DatabasePool;
  let client1AccessToken: string;
  let client2AccessToken: string;

  beforeAll(async () => {
    pool = createPool(config.databaseUrl);
    await Promise.all([
      pool.query(sql`delete from lookup.phone_data`),
      pool.query(sql`delete from lookup.lookups`),
      pool.query(sql`delete from lookup.accesses`),
      pool.query(sql`delete from lookup.requests`),
    ]);

    const responseOne = await supertest(app)
      .post('/admin/register')
      .set('token', config.adminAccessToken)
      .send({ name: client1Name });

    const responseTwo = await supertest(app)
      .post('/admin/register')
      .set('token', config.adminAccessToken)
      .send({ name: client2Name });

    client1AccessToken = responseOne.body.access_token;
    client2AccessToken = responseTwo.body.access_token;
  });

  afterAll(async () => {
    await pool.end();
  });

  test('createRequest should require an access token', async () => {
    const response = await supertest(app)
      .post('/lookup/graphql')
      .use(ql(`mutation createRequest() { request { id } }`));

    expect(response.status).toBe(401);
  });

  let requestId: string;

  test('createRequest should return a request id', async () => {
    const response = await supertest(app)
      .post('/lookup/graphql')
      .set('token', client1AccessToken)
      .use(
        ql(
          `mutation {
            createRequest(input: {request: {}}) {
              request {
                id
              }
            }
          }`
        )
      );

    expect(response.body).toHaveProperty('data');
    expect(response.body.data).toHaveProperty('createRequest');
    expect(response.body.data.createRequest).toHaveProperty('request');
    expect(response.body.data.createRequest.request).toHaveProperty('id');
    expect(typeof response.body.data.createRequest.request.id).toBe('string');
    requestId = response.body.data.createRequest.request.id;
  });

  test('addPhoneNumbersToRequest should return the request and count added', async () => {
    const response = await supertest(app)
      .post('/lookup/graphql')
      .set('token', client1AccessToken)
      .use(
        ql(
          `mutation addPhoneNumbersToRequest($phoneNumbers: [String], $requestId: UUID!) {
            addPhoneNumbersToRequest(input: {requestId: $requestId, phoneNumbers: $phoneNumbers}) {
              request {
                id
              }
              countAdded
            }
          }`,
          { phoneNumbers: [knownPhoneOne, knownPhoneTwo], requestId }
        )
      );

    expect(response.body.data.addPhoneNumbersToRequest).toHaveProperty(
      'request'
    );
    expect(typeof response.body.data.addPhoneNumbersToRequest.countAdded).toBe(
      'number'
    );
  });

  test('closeRequest should close it', async () => {
    const response = await supertest(app)
      .post('/lookup/graphql')
      .set('token', client1AccessToken)
      .use(
        ql(
          `mutation closeRequest($requestId: UUID!) {
            closeRequest(input: {requestId: $requestId}) {
              request {
                closedAt
                id
              }
            }
          }`,
          { requestId }
        )
      );

    expect(response.body.data.closeRequest).toHaveProperty('request');
  });

  test('requestProgress should return a number', async () => {
    const response = await supertest(app)
      .post('/lookup/graphql')
      .set('token', client1AccessToken)
      .use(
        ql(
          `mutation requestProgress($requestId: UUID!) {
            requestProgress(input: {requestId: $requestId}) {
              requestProgressResult {
                completedAt
                progress
              }
            }
          }`,
          { requestId }
        )
      );

    expect(response.body.data.requestProgress).toHaveProperty(
      'requestProgressResult'
    );

    expect(
      response.body.data.requestProgress.requestProgressResult != null
    ).toBe(true);
  });

  test('GET /lookup/:number should return the info', async () => {
    const response = await supertest(app)
      .get(`/lookup/json/lookup/${knownPhoneOne}`)
      .set('token', client1AccessToken);

    expect(response.body).toHaveProperty('phone_number');
  });

  test('A second GET /lookup/:number should not add another lookup entry', async () => {
    const response = await supertest(app)
      .get(`/lookup/json/lookup/${knownPhoneOne}`)
      .set('token', client2AccessToken);

    expect(response.body).toHaveProperty('phone_number');

    const {
      rows: [{ count: lookupCount }],
    } = await pool.query<{ count: number }>(
      sql`select count(*) as count from lookup.lookups`
    );

    const {
      rows: [{ count: accessCount }],
    } = await pool.query<{ count: number }>(
      sql`select count(*) as count from lookup.accesses where phone_number = ${knownPhoneOne}`
    );

    expect(lookupCount).toBe(1);
    expect(accessCount).toBe(3); // there's one from the graphql request
  });
});
