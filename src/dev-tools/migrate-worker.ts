import { makeWorkerUtils } from 'graphile-worker';

import config from '../config';

const main = async () => {
  const graphileWorker = await makeWorkerUtils({
    connectionString: config.databaseUrl,
  });
  await graphileWorker.migrate();
  await graphileWorker.release();
};

main()
  .then(() => {
    process.exit(0);
  })
  .catch((err) => {
    // tslint:disable-next-line: no-console
    console.error(err);
    process.exit(1);
  });
