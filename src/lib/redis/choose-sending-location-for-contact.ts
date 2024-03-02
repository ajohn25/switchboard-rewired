import { ChainableCommander } from 'ioredis';
import chunk from 'lodash/chunk';
import sortBy from 'lodash/sortBy';
import usZips from 'us-zips/map';
import zipState from 'zip-state';

import { sending_locations } from '../db-types';
import { RedisClient, RedisIndexSpec } from './redis-index';

/**
 * This index maintains a list of
 */

type EncodedSendingLocation<
  UUID extends string = string,
  State extends string = string
> = `${UUID}|${State}`;

/**
 * ioredis-mock does not support geoadd :(
 * https://github.com/stipsan/ioredis-mock/blob/main/compat.md#supported-commands-
 *
 * Since geo is just a multi key sorted set, we can provide a wrapper over sorted sets
 * that only uses 1 geographical point in testing
 *
 * Therefore, fake pipelineGeoAdd and geoRadius
 */

// This was the best property I saw for checking if it is redis-mock or not
// No official way to do so in the documentation
const isRedisMock = (thing: any) =>
  'data' in thing || ('redis' in thing && 'data' in thing.redis);

const isRealRedis = (thing: ChainableCommander | RedisClient) =>
  !isRedisMock(thing);

const pipelineGeoAdd = (
  pipeline: ChainableCommander,
  key: string,
  x: number,
  y: number,
  value: string
) => {
  if (isRealRedis(pipeline)) {
    return pipeline.geoadd(key, x, y, value);
  }
  return pipeline.zadd(key, x, value);
};

const geoRadius = async (
  redis: RedisClient,
  key: string,
  x: number,
  y: number
) => {
  if (isRealRedis(redis)) {
    return redis.georadius(key, x, y, 1e9, 'mi', 'ASC');
  }
  {
    // this is an array of alternating keys and scores
    const options = await redis.zrange(key, -1e9, 1e9, 'WITHSCORES');
    const organized = chunk(options, 2);
    const sorted = sortBy(organized, (option) =>
      Math.abs(parseFloat(option[1]) - x)
    );
    const sortedKeysOnly = sorted.map((option) => option[0]);
    return sortedKeysOnly;
  }
};

const getLocationOrBestGuess = (zipCode: string) => {
  const location = usZips.get(zipCode);

  if (location) return location;

  // We need to find the next best guess - the first three numbers should be close enough, falling back to lower matches
  // if necessary
  const asArray = [...usZips.keys()];
  const maybeTripleMatch = asArray.find((zip) =>
    zip.startsWith(zipCode.slice(0, 3))
  );

  if (maybeTripleMatch) return usZips.get(maybeTripleMatch);

  const maybeDoubleMatch = asArray.find((zip) =>
    zip.startsWith(zipCode.slice(0, 2))
  );

  if (maybeDoubleMatch) return usZips.get(maybeDoubleMatch);

  const maybeSingleMatch = asArray.find((zip) =>
    zip.startsWith(zipCode.slice(0, 1))
  );

  if (maybeSingleMatch) return usZips.get(maybeSingleMatch);

  // Omaha, NE, chosen for no reason at all
  return usZips.get('68102');
};

export const CHOOSE_SENDING_LOCATION_FOR_CONTACT: RedisIndexSpec<
  string | undefined,
  { contactZipCode: string }
> = {
  name: 'getSendingLocationForContact',
  fn: async ({ redis }, profileId, param) => {
    const key = `${profileId}-sendingLocations`;
    const contactLatLng = getLocationOrBestGuess(param.contactZipCode)!;
    const stateToMatch = zipState(param.contactZipCode);

    const sorted = (await geoRadius(
      redis,
      key,
      contactLatLng.longitude,
      contactLatLng.latitude
    )) as EncodedSendingLocation[];

    const firstMatchInState = sorted.find((sl: EncodedSendingLocation) => {
      const [uuid, state] = sl.split('|');
      return state === stateToMatch;
    });

    const maybeFallbackToOutOfState = firstMatchInState || sorted[0];

    const [sendingLocatiodId] = maybeFallbackToOutOfState
      ? maybeFallbackToOutOfState.split('|')
      : [undefined];

    return sendingLocatiodId;
  },
  hydrate: async ({ pg, redis }, profileId) => {
    const { rows: sendingLocations } = await pg.query<sending_locations>(
      `select * from sms.sending_locations where profile_id = $1
      and decomissioned_at is null`,
      [profileId]
    );

    const key = `${profileId}-sendingLocations`;

    const toExec = sendingLocations.reduce((pipeline, sendingLocation) => {
      const encodedSendingLocation: EncodedSendingLocation = `${sendingLocation.id}|${sendingLocation.state}`;

      return pipelineGeoAdd(
        pipeline,
        key,
        sendingLocation.location!.y,
        sendingLocation.location!.x,
        encodedSendingLocation
      );
    }, redis.pipeline());

    await toExec.exec();
  },
  addHandlers: (emitter, env, profileId, rehydrate) => {
    emitter.on(profileId, 'modified:sending_locations', async () => {
      await rehydrate();
    });

    return () => {
      emitter.offAll(profileId, 'modified:sending_locations');
    };
  },
};
