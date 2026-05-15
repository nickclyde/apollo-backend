ALTER TABLE accounts
    DROP COLUMN IF EXISTS reddit_client_id,
    DROP COLUMN IF EXISTS reddit_client_secret,
    DROP COLUMN IF EXISTS reddit_redirect_uri,
    DROP COLUMN IF EXISTS reddit_user_agent;
