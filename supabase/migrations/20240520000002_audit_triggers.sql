-- Audit Log Trigger for Inventory
CREATE OR REPLACE FUNCTION public.audit_inventory_change()
RETURNS trigger AS $$
BEGIN
  IF (TG_OP = 'UPDATE') THEN
    INSERT INTO public.audit_logs (user_id, action, target_table, target_id, old_value, new_value)
    VALUES (auth.uid(), 'UPDATE', 'inventory', NEW.id, to_jsonb(OLD), to_jsonb(NEW));
  ELSIF (TG_OP = 'INSERT') THEN
    INSERT INTO public.audit_logs (user_id, action, target_table, target_id, new_value)
    VALUES (auth.uid(), 'INSERT', 'inventory', NEW.id, to_jsonb(NEW));
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER audit_inventory_changes
  AFTER INSERT OR UPDATE ON public.inventory
  FOR EACH ROW EXECUTE PROCEDURE public.audit_inventory_change();