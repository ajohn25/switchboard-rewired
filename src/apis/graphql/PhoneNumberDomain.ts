import type { SchemaBuilder } from 'graphile-build';

import { normalize } from '../../lib/utils';

/**
 * Modeled off of https://www.graphile.org/postgraphile/plugin-gallery/#Customisation__SanitizeHTMLTypePlugin
 */

export default (builder: SchemaBuilder) => {
  builder.hook('init', (_, build) => {
    const {
      pgIntrospectionResultsByKind, // From PgIntrospectionPlugin
      pg2GqlMapper, // From PgTypesPlugin
      pgSql: sql, // From PgBasicsPlugin, this is equivalent to `require('pg-sql2')` but avoids multiple-module conflicts
    } = build;

    const phoneNumberDomain = pgIntrospectionResultsByKind.type.find(
      (type: any) =>
        type.name === 'phone_number' && type.namespaceName === 'public'
    );

    if (phoneNumberDomain) {
      pg2GqlMapper[phoneNumberDomain.id] = {
        map: (value: any) => value,
        unmap: (value: any) =>
          sql.fragment`(${sql.value(normalize(value))}::public.phone_number)`,
      };
    }

    return _;
  });
};
