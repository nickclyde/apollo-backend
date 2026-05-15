ALTER TABLE accounts
    ADD COLUMN reddit_client_id     varchar(64)  NOT NULL DEFAULT '',
    ADD COLUMN reddit_client_secret varchar(128) NOT NULL DEFAULT '',
    ADD COLUMN reddit_redirect_uri  varchar(255) NOT NULL DEFAULT '',
    ADD COLUMN reddit_user_agent    varchar(255) NOT NULL DEFAULT '';
