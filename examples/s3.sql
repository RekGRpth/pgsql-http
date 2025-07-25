--
-- s3_request
--
-- Installation:
--
--   CREATE EXTENSION pgcrypto;
--   CREATE EXTENSION http;
--
-- Utility function to take S3 object and access keys and create
-- a signed HTTP request using the AWS4 signing scheme.
-- https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html
-- 
-- Various pieces of the request are gathered into strings bundled together
-- and ultimately signed with the s3 secret key.
--
-- Example:
--
-- https://cleverelephant-west-1.s3.amazonaws.com/META.json
--
-- SELECT * FROM s3_request(
--     'your_s3_access_key',      -- access
--     'your_s3_secret_key',      -- secret
--     'us-west-1',               -- region
--     'cleverelephant-west-1',   -- bucket
--     'META.json',               -- object name
-- );
--
--
-- Create and delete objects too!
--
-- SELECT * FROM s3_request(
--     'your_s3_access_key',      -- access
--     'your_s3_secret_key',      -- secret
--     'us-west-1',               -- region
--     'cleverelephant-west-1',   -- bucket
--     'testfile.txt',            -- object name
--     'PUT',                     -- http method
--     'this is a test'           -- payload
--     'text/plain'               -- payload mime type
-- );
--
-- SELECT * FROM s3_request(
--     'your_s3_access_key',      -- access
--     'your_s3_secret_key',      -- secret
--     'us-west-1',               -- region
--     'cleverelephant-west-1',   -- bucket
--     'testfile.txt',            -- object name
-- );
--
-- SELECT * FROM s3_request(
--     'your_s3_access_key',      -- access
--     'your_s3_secret_key',      -- secret
--     'us-west-1',               -- region
--     'cleverelephant-west-1',   -- bucket
--     'testfile.txt',            -- object name
--     'DELETE'                   -- http method
-- );
--

CREATE OR REPLACE FUNCTION s3_request(
    access_key TEXT,
    secret_key TEXT,
    region TEXT,
    bucket TEXT,
    object_key TEXT,
    http_method TEXT DEFAULT 'GET',
    object_payload TEXT DEFAULT NULL,
    object_mimetype TEXT DEFAULT 'text/plain'
) RETURNS http_response AS $$
DECLARE
    host TEXT := bucket || '.s3.' || region || '.amazonaws.com';
    endpoint TEXT := 'https://' || host || '/' || object_key;
    canonical_uri TEXT := '/' || object_key;
    canonical_querystring TEXT := '';
    signed_headers TEXT := 'host;x-amz-content-sha256;x-amz-date';
    service TEXT := 's3';
    
    now TIMESTAMP := now() AT TIME ZONE 'UTC';
    amz_date TEXT := to_char(now, 'YYYYMMDD"T"HH24MISS"Z"');
    date_stamp TEXT := to_char(now, 'YYYYMMDD');

    -- Must use this magic hash if the payload is empty
    payload_hash TEXT := 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    canonical_headers TEXT;
    canonical_request TEXT;
    string_to_sign TEXT;
    credential_scope TEXT;
    date_key BYTEA; 
    date_region_key BYTEA;
    date_region_service_key BYTEA;
    signing_key BYTEA;
    signature TEXT;
    authorization_header TEXT;
    canonical_request_digest TEXT;
    request http_request;
BEGIN

    http_method := upper(http_method);
    object_mimetype := lower(object_mimetype);

    IF object_payload IS NOT NULL
    THEN
        payload_hash := encode(digest(convert_to(object_payload, 'UTF8'), 'sha256'), 'hex');
    END IF;

    -- Construct the canonical headers
    canonical_headers := 'host:' || host || E'\n' 
                      || 'x-amz-content-sha256:' || payload_hash || E'\n'
                      || 'x-amz-date:' || amz_date || E'\n';

    -- Signed headers must be in alphabetical order
    -- so content-type goes first
    IF object_payload IS NOT NULL
    THEN
        canonical_headers := 'content-type:' || object_mimetype || E'\n' || canonical_headers;
        signed_headers :=  'content-type;' || signed_headers;
    END IF;

    -- Create the canonical request
    canonical_request := http_method || E'\n' ||
                         canonical_uri || E'\n' ||
                         canonical_querystring || E'\n' ||
                         canonical_headers || E'\n' ||
                         signed_headers || E'\n' ||
                         payload_hash;

    -- Define the credential scope
    credential_scope := date_stamp || '/' || region || '/' || service || '/aws4_request';

    -- Get sha256 hash of request
    canonical_request_digest := encode(digest(canonical_request, 'sha256'), 'hex');

    -- Create the string to sign
    string_to_sign := 'AWS4-HMAC-SHA256' || E'\n' ||
                      amz_date || E'\n' ||
                      credential_scope || E'\n' ||
                      canonical_request_digest;

    --
    -- Signature of pgcrypto function is hmac(payload, secret, algo)
    -- Each piece of the signing key is bundled together with the 
    -- previous piece, starting with the S3 secret key.
    --
    date_key := hmac(convert_to(date_stamp, 'UTF8'), convert_to('AWS4' || secret_key, 'UTF8'), 'sha256');
    date_region_key := hmac(convert_to(region, 'UTF8'), date_key, 'sha256');
    date_region_service_key := hmac(convert_to(service, 'UTF8'), date_region_key, 'sha256');
    signing_key := hmac(convert_to('aws4_request','UTF8'), date_region_service_key, 'sha256');

    -- Compute the signature
    signature := encode(hmac(convert_to(string_to_sign, 'UTF8'), signing_key, 'sha256'), 'hex');

    -- Construct the Authorization header
    authorization_header := 'AWS4-HMAC-SHA256 Credential=' || access_key || '/' || credential_scope ||
                            ', SignedHeaders=' || signed_headers ||
                            ', Signature=' || signature;


    -- Perform the HTTP request
    request := (
            http_method,
            endpoint,
            http_headers('Authorization', authorization_header,
                         'x-amz-content-sha256', payload_hash,
                         'x-amz-date', amz_date,
                         'host', host),
            object_mimetype,
            object_payload
        )::http_request;

    -- Getting the canonical request and payload strings perfectly 
    -- formatted is an important step so debugging here in case
    -- S3 rejects signed request
    RAISE DEBUG 's3_request, payload_hash: %', payload_hash;
    RAISE DEBUG 's3_request, canonical_request: %', canonical_request;
    RAISE DEBUG 's3_request, string_to_sign: %', string_to_sign;
    RAISE DEBUG 's3_request, request %', request;

    RETURN http(request);

END;
$$ LANGUAGE 'plpgsql'
VOLATILE;
