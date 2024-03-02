-- Revert parked jobs table
-- ----------------------------

drop table worker.failed_jobs;
drop schema worker;
