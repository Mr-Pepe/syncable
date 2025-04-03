create or replace function discard_older_updates()
returns trigger as $$
BEGIN
    IF NEW.updated_at <= OLD.updated_at THEN
        RETURN NULL; -- Discard the incoming row
    END IF;
    RETURN NEW; -- Allow the update to proceed
END;
$$ language plpgsql;
