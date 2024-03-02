import { danger, fail, TextDiff } from 'danger';

/**
 * Parses the diff returned by Danger into the actual lines of text added/removed
 * @param diff Danger diff object
 */
const parseDiff = (diff: TextDiff) => {
  const addedLines = diff.added
    .split('\n')
    .map((line) => line.replace(/^\+/, ''));
  const removedLines = diff.removed
    .split('\n')
    .map((line) => line.replace(/^-/, ''));
  return { addedLines, removedLines };
};

/**
 * Return true if the line of SQL is neither empty nor a comment
 * @param line line of SQL code to check
 */
const isSqlContent = (line: string) => line !== '' && !line.startsWith('--');

const isMigration = (file: string) => /^migrations\/.*\.sql$/.test(file);

// Check if there have been substantive changes to migrations without a change to schema-dump.sql
const sqlDumpModified = danger.git.modified_files.includes('schema-dump.sql');
const modifiedMigrations = danger.git.modified_files.filter(isMigration);
const addedMigrations = danger.git.created_files.filter(isMigration);
const changedMigrations = [...addedMigrations, ...modifiedMigrations];
if (changedMigrations.length > 0 && !sqlDumpModified) {
  Promise.all(
    changedMigrations.map(async (changedMigration) => {
      const diff = await danger.git.diffForFile(changedMigration);
      const { addedLines, removedLines } = parseDiff(diff);
      if (addedLines.find(isSqlContent) || removedLines.find(isSqlContent)) {
        fail(
          'Migration was edited without running ./update-dump.sh',
          changedMigration
        );
      }
    })
  );
}
