-- Module 11: makes the first start of PostgreSQL a few seconds slower, the way a large database
-- or a slow disk would. While init scripts run, PostgreSQL listens only on its Unix socket.
SELECT pg_sleep(8);
