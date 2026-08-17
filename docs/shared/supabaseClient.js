// Antojito's Cakes — Gestión de Producción
// Cliente Supabase compartido por todas las páginas del módulo.
//
// IMPORTANTE: reemplazar SUPABASE_URL y SUPABASE_ANON_KEY con los valores
// reales del proyecto (Supabase → Project Settings → API). El "anon key" es
// seguro de exponer en el navegador: quien decide qué se puede leer/escribir
// es Row Level Security (RLS) en la base de datos, no el secreto de esta key.

const SUPABASE_URL = 'https://xxenjrgsgglewtthembj.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inh4ZW5qcmdzZ2dsZXd0dGhlbWJqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ0MTI1NTIsImV4cCI6MjA5OTk4ODU1Mn0.van8zgHZabSHxfqoMrEiCPPMP5Kh80jSJTlmoXK_NkA';

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: true, autoRefreshToken: true }
});

/**
 * Ruta relativa a la raíz del módulo (Gestion_Produccion/) desde la página actual.
 * Las páginas de nivel raíz (login.html, home.html) usan '', las de subcarpetas
 * (recetas/*.html) usan '../'.
 */
function rutaBase() {
  const subcarpetas = ['/recetas/', '/escandallo/', '/administracion/', '/logs/', '/inventario/', '/produccion/', '/reportes/', '/pedidos/'];
  return subcarpetas.some(s => location.pathname.includes(s)) ? '../' : '';
}

/**
 * Exige una sesión activa; si no existe, redirige a login.html.
 * Devuelve { session, perfil } donde perfil viene de la tabla `perfiles`.
 */
async function requireSession() {
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (!session) {
    location.href = rutaBase() + 'login.html';
    return null;
  }

  const { data: perfil, error } = await supabaseClient
    .from('perfiles')
    .select('id, nombre, rol, activo, sede')
    .eq('id', session.user.id)
    .single();

  if (error || !perfil || !perfil.activo) {
    await supabaseClient.auth.signOut();
    location.href = rutaBase() + 'login.html';
    return null;
  }

  return { session, perfil };
}

/** true si el rol del perfil está en la lista de roles permitidos */
function tieneRol(perfil, rolesPermitidos) {
  return !!perfil && rolesPermitidos.includes(perfil.rol);
}

/** Pinta el badge de usuario/rol en el header y conecta el botón de logout */
function pintarUsuario(perfil, elId) {
  const el = document.getElementById(elId);
  if (!el) return;
  el.innerHTML = `
    <span>${perfil.nombre}</span>
    <span class="rol-badge">${perfil.rol}</span>
    <button id="btnLogout">Salir</button>
  `;
  document.getElementById('btnLogout').addEventListener('click', async () => {
    await supabaseClient.auth.signOut();
    location.href = rutaBase() + 'login.html';
  });
}

/**
 * Revisa lotes en exhibición y stock de materia prima, y genera alertas en la
 * tabla `alertas` cuando corresponde (sin duplicar si ya existe una sin resolver
 * para el mismo lote/ingrediente). Se llama al cargar home.html e inventario/index.html.
 */
async function verificarAlertasInventario(perfil) {
  if (!tieneRol(perfil, ['administrador', 'produccion', 'inventario'])) return;

  const hoy = new Date();

  const { data: parametros } = await supabaseClient
    .from('inventario_parametros').select('*').eq('id', 1).single();
  const diasDefault = parametros?.dias_alerta_exhibicion ?? 3;

  const { data: lotes } = await supabaseClient
    .from('lotes')
    .select('id, sede, fecha_ingreso, recetas(nombre, dias_alerta_exhibicion)')
    .is('retirado_at', null);

  for (const lote of lotes || []) {
    const dias = Math.floor((hoy - new Date(lote.fecha_ingreso + 'T00:00:00')) / 86400000);
    const umbral = lote.recetas?.dias_alerta_exhibicion ?? diasDefault;
    if (dias >= umbral) {
      await crearAlertaSiNoExiste({
        tipo: 'vencimiento',
        nivel: dias >= umbral * 2 ? 'critica' : 'advertencia',
        mensaje: `${lote.recetas?.nombre || 'Producto'} lleva ${dias} día(s) en exhibición (${lote.sede})`,
        modulo: 'inventario',
        referencia_id: lote.id,
      });
    }
  }

  const { data: ingredientes } = await supabaseClient
    .from('ingredientes')
    .select('id, nombre, unidad_medida, stock_actual, stock_minimo')
    .eq('activo', true)
    .not('stock_minimo', 'is', null);

  for (const ing of ingredientes || []) {
    if (Number(ing.stock_actual) <= Number(ing.stock_minimo)) {
      await crearAlertaSiNoExiste({
        tipo: 'stock',
        nivel: 'critica',
        mensaje: `${ing.nombre} por debajo del mínimo (quedan ${Number(ing.stock_actual)} ${ing.unidad_medida})`,
        modulo: 'inventario',
        referencia_id: ing.id,
      });
    }
  }
}

async function crearAlertaSiNoExiste({ tipo, nivel, mensaje, modulo, referencia_id }) {
  const { data: existente } = await supabaseClient
    .from('alertas')
    .select('id')
    .eq('referencia_id', referencia_id)
    .eq('modulo', modulo)
    .eq('resuelta', false)
    .limit(1);
  if (existente && existente.length) return;
  await supabaseClient.from('alertas').insert({ tipo, nivel, mensaje, modulo, referencia_id });
}

// Registra el service worker (necesario para que el navegador ofrezca "Instalar app").
// No cachea datos de Supabase, solo el cascarón estático (ver service-worker.js).
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register(rutaBase() + 'service-worker.js').catch(() => {});
  });
}

/**
 * Fuerza un refresco inmediato de la tasa BCV llamando la misma Edge Function que
 * dispara el cron diario. Devuelve la fila actualizada de `tasa_cambio`, o lanza error.
 */
async function actualizarTasaBcvAhora() {
  const res = await fetch(`${SUPABASE_URL}/functions/v1/actualizar-tasa-bcv`, {
    method: 'POST',
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || body.ok === false) {
    throw new Error(body.error || `La función respondió ${res.status}`);
  }
  const { data } = await supabaseClient.from('tasa_cambio').select('*').eq('id', 1).single();
  return data;
}

/** Muestra un toast simple (éxito o error) */
function toast(mensaje, tipo = 'ok') {
  let el = document.getElementById('toast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'toast';
    el.className = 'toast';
    document.body.appendChild(el);
  }
  el.textContent = mensaje;
  el.className = 'toast show' + (tipo === 'error' ? ' error' : '');
  clearTimeout(el._timeout);
  el._timeout = setTimeout(() => el.classList.remove('show'), 3000);
}
