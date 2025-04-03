CREATE OR REPLACE FUNCTION discard_older_updates()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.updated_at <= OLD.updated_at THEN
        RETURN NULL; -- Discard the incoming row
    END IF;
    RETURN NEW; -- Allow the update to proceed
END;
$$ LANGUAGE plpgsql;
