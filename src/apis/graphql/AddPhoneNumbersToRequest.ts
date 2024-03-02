import { gql, makeExtendSchemaPlugin } from 'graphile-utils';
import partition from 'lodash/partition';
import { normalize } from '../../lib/utils';

export default makeExtendSchemaPlugin((build) => {
  const { pgSql: sql } = build;

  return {
    resolvers: {
      Mutation: {
        addPhoneNumbersToRequest: async (
          _query,
          args,
          context,
          resolveInfo
        ) => {
          const requestId: string = args.input.requestId;
          const phoneNumbers: [string] = args.input.phoneNumbers;
          const { pgClient } = context;

          const normalizedNumbers = phoneNumbers.map((phoneNumber) => [
            phoneNumber,
            normalize(phoneNumber),
          ]);

          const [validNumbersTuples, invalidNumbersTuples] = partition(
            normalizedNumbers,
            ([_number, normalizationResult]) =>
              normalizationResult !== 'invalid'
          );

          const invalidNumbers = invalidNumbersTuples.map(
            ([phoneNumber, _normalizationResult]) => phoneNumber
          );

          const validNumbers = validNumbersTuples.map(
            ([_number, normalizationResult]) => normalizationResult
          );

          if (validNumbers.length > 0) {
            const query = sql.compile(
              sql.query`
              insert into lookup.accesses (request_id, phone_number)
              values ${sql.join(
                validNumbers.map(
                  (n) => sql.query`(${sql.value(requestId)}, ${sql.value(n)})`
                ),
                ','
              )}
              on conflict on constraint unique_phone_number_request do nothing
            `
            );

            await pgClient.query(query);
          }

          const requests =
            await resolveInfo.graphile.selectGraphQLResultFromTable(
              sql.fragment`lookup.requests`,
              (_tableAlias, queryBuilder) => {
                queryBuilder.where(sql.fragment`id = ${sql.value(requestId)}`);
              }
            );

          const request = requests[0];

          return {
            invalidNumbers,
            countAdded: validNumbers.length,
            data: request,
          };
        },
      },
    },
    typeDefs: gql`
      input AddPhoneNumbersToRequestInput {
        requestId: UUID!
        phoneNumbers: [String]
      }

      type AddPhoneNumbersToRequestPayload {
        request: Request! @pgField
        countAdded: Int!
        invalidNumbers: [String]
      }

      extend type Mutation {
        addPhoneNumbersToRequest(
          input: AddPhoneNumbersToRequestInput!
        ): AddPhoneNumbersToRequestPayload!
      }
    `,
  };
});
