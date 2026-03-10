import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    const {
      data: { user },
    } = await supabaseClient.auth.getUser()

    if (!user) throw new Error('Unauthorized')

    const { changes } = await req.json()
    // changes: { table: string, records: any[] }[]

    const results = []

    for (const change of changes) {
      const { table, records } = change
      
      // Upsert records into the table
      // Supabase .upsert() handles conflicts by default using primary keys
      const { data, error } = await supabaseClient
        .from(table)
        .upsert(records, { onConflict: 'id', ignoreDuplicates: false })

      if (error) {
        results.push({ table, success: false, error: error.message })
      } else {
        results.push({ table, success: true, count: data?.length || 0 })
      }
    }

    return new Response(JSON.stringify({ results }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})