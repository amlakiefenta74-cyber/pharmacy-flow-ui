-- Initial Migration for Pharmatopia
-- Created: 2024-05-20 (Example Timestamp)

-- Enable pgcrypto for UUID generation if needed
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 1. BRANCHES
CREATE TABLE IF NOT EXISTS public.branches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    location TEXT,
    contact_number TEXT,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- 2. PROFILES (Extends Auth Users)
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    full_name TEXT,
    role TEXT CHECK (role IN ('owner', 'pharmacist', 'admin')) DEFAULT 'pharmacist',
    branch_id UUID REFERENCES public.branches(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- 3. PRODUCTS (Central Catalog)
CREATE TABLE IF NOT EXISTS public.products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    generic_name TEXT,
    description TEXT,
    sku TEXT UNIQUE,
    category TEXT,
    unit TEXT DEFAULT 'pcs',
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- 4. INVENTORY (Branch specific stock)
CREATE TABLE IF NOT EXISTS public.inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    branch_id UUID REFERENCES public.branches(id) ON DELETE CASCADE NOT NULL,
    product_id UUID REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
    quantity INTEGER DEFAULT 0 NOT NULL,
    batch_number TEXT,
    expiry_date DATE,
    low_stock_threshold INTEGER DEFAULT 10,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    UNIQUE(branch_id, product_id, batch_number)
);

-- 5. STOCK MOVEMENTS
CREATE TABLE IF NOT EXISTS public.stock_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    branch_id UUID REFERENCES public.branches(id) ON DELETE CASCADE NOT NULL,
    product_id UUID REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
    type TEXT CHECK (type IN ('received', 'sold', 'transferred', 'adjusted', 'expired')) NOT NULL,
    quantity INTEGER NOT NULL,
    reason TEXT,
    performed_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- 6. TRANSACTIONS (POS Sales)
CREATE TABLE IF NOT EXISTS public.transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    branch_id UUID REFERENCES public.branches(id) ON DELETE CASCADE NOT NULL,
    seller_id UUID REFERENCES public.profiles(id) NOT NULL,
    total_amount DECIMAL(12, 2) NOT NULL DEFAULT 0,
    discount_amount DECIMAL(12, 2) DEFAULT 0,
    payment_method TEXT DEFAULT 'cash',
    status TEXT CHECK (status IN ('completed', 'cancelled', 'refunded')) DEFAULT 'completed',
    offline_sync_id TEXT UNIQUE, -- For offline-first reconciliation
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- 7. TRANSACTION ITEMS
CREATE TABLE IF NOT EXISTS public.transaction_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID REFERENCES public.transactions(id) ON DELETE CASCADE NOT NULL,
    product_id UUID REFERENCES public.products(id) NOT NULL,
    quantity INTEGER NOT NULL,
    unit_price DECIMAL(12, 2) NOT NULL,
    subtotal DECIMAL(12, 2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- 8. ONLINE ORDERS (Marketplace)
CREATE TABLE IF NOT EXISTS public.online_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_name TEXT,
    contact_info TEXT,
    status TEXT CHECK (status IN ('pending', 'processing', 'completed', 'cancelled')) DEFAULT 'pending',
    total_amount DECIMAL(12, 2) NOT NULL DEFAULT 0,
    order_details JSONB, -- For flexiblity in products/quantities
    branch_id UUID REFERENCES public.branches(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- 9. AUDIT LOGS
CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id),
    action TEXT NOT NULL,
    target_table TEXT NOT NULL,
    target_id UUID,
    old_value JSONB,
    new_value JSONB,
    created_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- 10. SYSTEM SETTINGS
CREATE TABLE IF NOT EXISTS public.settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    branch_id UUID REFERENCES public.branches(id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    value JSONB,
    updated_at TIMESTAMPTZ DEFAULT now() NOT NULL,
    UNIQUE(branch_id, key)
);

-- RLS POLICIES

-- Enable RLS
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transaction_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.online_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;

-- 1. Profiles: Users can read all, update own
CREATE POLICY "Profiles are viewable by everyone" ON public.profiles FOR SELECT USING (true);
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id);

-- 2. Branches: Everyone can view, Admins/Owners can manage
CREATE POLICY "Branches viewable by authenticated" ON public.branches FOR SELECT TO authenticated USING (true);
CREATE POLICY "Only owners/admins can manage branches" ON public.branches ALL TO authenticated 
    USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('owner', 'admin')));

-- 3. Products: Viewable by all, managed by owners/admins
CREATE POLICY "Products viewable by authenticated" ON public.products FOR SELECT TO authenticated USING (true);
CREATE POLICY "Products managed by owners/admins" ON public.products ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('owner', 'admin')));

-- 4. Inventory: Branch staff can view/edit their branch, owners see all
CREATE POLICY "Inventory branch access" ON public.inventory FOR ALL TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.profiles 
            WHERE id = auth.uid() 
            AND (role = 'owner' OR (role = 'pharmacist' AND branch_id = inventory.branch_id))
        )
    );

-- 5. Transactions: Users view their branch, owners see all
CREATE POLICY "Transaction branch access" ON public.transactions FOR ALL TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.profiles 
            WHERE id = auth.uid() 
            AND (role = 'owner' OR (role = 'pharmacist' AND branch_id = transactions.branch_id))
        )
    );

-- 6. Transaction Items: Inherit from transactions policy
CREATE POLICY "Transaction items access" ON public.transaction_items FOR ALL TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.transactions t
            JOIN public.profiles p ON p.id = auth.uid()
            WHERE t.id = transaction_items.transaction_id
            AND (p.role = 'owner' OR (p.role = 'pharmacist' AND p.branch_id = t.branch_id))
        )
    );

-- Functions & Triggers for updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_branches_updated_at BEFORE UPDATE ON public.branches FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();
CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();
CREATE TRIGGER update_products_updated_at BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();
CREATE TRIGGER update_inventory_updated_at BEFORE UPDATE ON public.inventory FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();
CREATE TRIGGER update_transactions_updated_at BEFORE UPDATE ON public.transactions FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();
CREATE TRIGGER update_online_orders_updated_at BEFORE UPDATE ON public.online_orders FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();
CREATE TRIGGER update_settings_updated_at BEFORE UPDATE ON public.settings FOR EACH ROW EXECUTE PROCEDURE update_updated_at_column();

-- Function to handle stock subtraction on sale
CREATE OR REPLACE FUNCTION public.handle_stock_reduction()
RETURNS TRIGGER AS $$
BEGIN
    -- This is a simplified version. In real app, you might want to specify batch.
    UPDATE public.inventory
    SET quantity = quantity - NEW.quantity
    WHERE product_id = NEW.product_id
    AND branch_id = (SELECT branch_id FROM public.transactions WHERE id = NEW.transaction_id);
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER on_transaction_item_insert
    AFTER INSERT ON public.transaction_items
    FOR EACH ROW EXECUTE PROCEDURE public.handle_stock_reduction();