// Wireless-ADB helper page: discover phone debug endpoints over mDNS, pair
// with the 6-digit code, connect, and expose a copy-to-clipboard for the
// "ip:port" string so the user can hand it off to an agent or terminal.
//
// The phone broadcasts two service types:
//   _adb-tls-pairing._tcp  - alive only while the "Pair with code" dialog is up
//   _adb-tls-connect._tcp  - alive whenever Wireless debugging is on
// We render them as two stacked sections so the workflow is obvious:
//   1) See a pairing endpoint → type the 6-digit code → Pair
//   2) See a debug endpoint → Connect → done
import {useEffect, useState} from 'react';
import {t, useLocale} from '../i18n';
import {EventsOn} from '../../wailsjs/runtime/runtime';
import {
    AdbConnect,
    AdbDevices,
    AdbDisconnect,
    AdbPair,
    AdbVersion,
    GetAdbEndpoints,
    StartAdbDiscovery,
} from '../../wailsjs/go/main/App';
import {adbwireless} from '../../wailsjs/go/models';

type Endpoint = adbwireless.Endpoint;
type Device = adbwireless.Device;

// Wails only exposes Go struct *fields* to TypeScript, not methods, so the
// Endpoint.Address() helper on the Go side isn't reachable here. Re-derive it.
function addr(ep: Endpoint): string { return `${ep.host}:${ep.port}`; }

export function AdbPage() {
    useLocale();
    const [endpoints, setEndpoints] = useState<Endpoint[]>([]);
    const [devices, setDevices] = useState<Device[]>([]);
    const [version, setVersion] = useState<string>('');
    const [versionErr, setVersionErr] = useState<string>('');
    const [busy, setBusy] = useState<string>(''); // address currently mid-action
    const [hint, setHint] = useState<string>('');
    const [hintKind, setHintKind] = useState<'ok' | 'err' | ''>('');
    const [pairingCodes, setPairingCodes] = useState<Record<string, string>>({});
    const [copiedAddr, setCopiedAddr] = useState<string>('');

    useEffect(() => {
        AdbVersion().then(setVersion).catch((e) => setVersionErr(String(e)));
        StartAdbDiscovery().catch((e) => setHint('discovery: ' + e));
        GetAdbEndpoints().then(setEndpoints).catch(() => {});
        refreshDevices();
        const off = EventsOn('adb:endpoints', (eps: Endpoint[]) => setEndpoints(eps || []));
        return () => {
            // Only drop the event subscription — deliberately do NOT call
            // StopAdbDiscovery() here. The discoverer stays running in the
            // background so endpoints keep accumulating across tab switches;
            // tearing it down on unmount made every return to this tab restart
            // discovery from scratch and re-roll the mDNS race, which is exactly
            // the "endpoints only show up after I toggle tabs" symptom. It's
            // stopped for real once on app shutdown (App.shutdown).
            off();
        };
    }, []);

    function refreshDevices() {
        // Coerce a possible null (Go nil slice -> JSON null) back to [] so the
        // render's devices.length never throws.
        AdbDevices().then((d) => setDevices(d || [])).catch(() => setDevices([]));
    }

    function showHint(msg: string, kind: 'ok' | 'err') {
        setHint(msg);
        setHintKind(kind);
    }

    async function pair(ep: Endpoint) {
        const code = (pairingCodes[addr(ep)] || '').trim();
        if (code.length !== 6) {
            showHint('Pairing code must be 6 digits', 'err');
            return;
        }
        setBusy(addr(ep));
        try {
            const res = await AdbPair(addr(ep), code);
            showHint(t('adb.pairOk') + ' · ' + (res.raw || ''), 'ok');
            // Clear the field so a misclick doesn't re-pair stale data.
            setPairingCodes((p) => ({...p, [addr(ep)]: ''}));
            refreshDevices();
        } catch (e) {
            showHint(String(e), 'err');
        } finally {
            setBusy('');
        }
    }

    async function connect(ep: Endpoint) {
        setBusy(addr(ep));
        try {
            const out = await AdbConnect(addr(ep));
            showHint(out, out.toLowerCase().startsWith('connected') ? 'ok' : 'err');
            refreshDevices();
        } catch (e) {
            showHint(String(e), 'err');
        } finally {
            setBusy('');
        }
    }

    async function disconnect(serial: string) {
        setBusy(serial);
        try {
            const out = await AdbDisconnect(serial);
            showHint(out, 'ok');
            refreshDevices();
        } catch (e) {
            showHint(String(e), 'err');
        } finally {
            setBusy('');
        }
    }

    async function copyAddress(target: string) {
        try {
            await navigator.clipboard.writeText(target);
            setCopiedAddr(target);
            window.setTimeout(() => setCopiedAddr((cur) => (cur === target ? '' : cur)), 1200);
        } catch (e) {
            showHint(String(e), 'err');
        }
    }

    const pairings = endpoints.filter((e) => e.kind === 'pairing');
    const connects = endpoints.filter((e) => e.kind === 'connect');

    return (
        <div style={{display: 'flex', flexDirection: 'column', gap: 14, flex: 1, minHeight: 0}}>
            {/* ---- Header ---- */}
            <div className="card">
                <div className="card-header">
                    <div className="card-title">{t('adb.title')}</div>
                    <span className="muted">{t('adb.adbVersion')}: {versionErr ? t('adb.adbMissing') : (version || '…')}</span>
                </div>
                <div className="muted" style={{padding: '0 14px 12px'}}>{t('adb.sub')}</div>
            </div>

            {/* ---- Pairing endpoints ---- */}
            <div className="card">
                <div className="card-header">
                    <div className="card-title">{t('adb.pairingFound')}</div>
                </div>
                <div style={{padding: '4px 14px 14px', display: 'flex', flexDirection: 'column', gap: 8}}>
                    {pairings.length === 0 && <div className="muted">{t('adb.noPairing')}</div>}
                    {pairings.map((ep) => (
                        <div key={ep.kind + addr(ep)} style={{display: 'flex', alignItems: 'center', gap: 10}}>
                            <code style={{flex: 1, fontSize: 13}}>{addr(ep)}</code>
                            <input
                                style={{width: 110, padding: '6px 8px', fontSize: 13, fontFamily: 'inherit'}}
                                placeholder={t('adb.pairingCode')}
                                inputMode="numeric"
                                maxLength={6}
                                value={pairingCodes[addr(ep)] || ''}
                                onChange={(e) => setPairingCodes((p) => ({...p, [addr(ep)]: e.target.value.replace(/\D/g, '')}))}
                            />
                            <button className="ghost-btn primary"
                                    disabled={busy === addr(ep) || (pairingCodes[addr(ep)] || '').length !== 6}
                                    onClick={() => pair(ep)}>
                                {busy === addr(ep) ? '…' : t('adb.btnPair')}
                            </button>
                        </div>
                    ))}
                </div>
            </div>

            {/* ---- Debug (connect) endpoints ---- */}
            <div className="card">
                <div className="card-header">
                    <div className="card-title">{t('adb.connectFound')}</div>
                </div>
                <div style={{padding: '4px 14px 14px', display: 'flex', flexDirection: 'column', gap: 8}}>
                    {connects.length === 0 && <div className="muted">{t('adb.noConnect')}</div>}
                    {connects.map((ep) => (
                        <div key={ep.kind + addr(ep)} style={{display: 'flex', alignItems: 'center', gap: 10}}>
                            <code style={{flex: 1, fontSize: 13}}>{addr(ep)}</code>
                            <button className="ghost-btn"
                                    onClick={() => copyAddress(addr(ep))}>
                                {copiedAddr === addr(ep) ? t('adb.copied') : t('adb.btnCopy')}
                            </button>
                            <button className="ghost-btn primary"
                                    disabled={busy === addr(ep)}
                                    onClick={() => connect(ep)}>
                                {busy === addr(ep) ? '…' : t('adb.btnConnect')}
                            </button>
                        </div>
                    ))}
                </div>
            </div>

            {/* ---- adb devices ---- */}
            <div className="card">
                <div className="card-header">
                    <div className="card-title">{t('adb.devicesTitle')}</div>
                    <button className="ghost-btn" onClick={refreshDevices}>{t('adb.btnRefresh')}</button>
                </div>
                <div style={{padding: '4px 14px 14px', display: 'flex', flexDirection: 'column', gap: 8}}>
                    {devices.length === 0 && <div className="muted">{t('adb.noDevices')}</div>}
                    {devices.map((d) => (
                        <div key={d.serial} style={{display: 'flex', alignItems: 'center', gap: 10}}>
                            <code style={{flex: 1, fontSize: 13}}>
                                {d.serial}
                                <span className="muted"> · {d.state}{d.model ? ' · ' + d.model : ''}</span>
                            </code>
                            <button className="ghost-btn"
                                    onClick={() => copyAddress(d.serial)}>
                                {copiedAddr === d.serial ? t('adb.copied') : t('adb.btnCopy')}
                            </button>
                            {/* Only wireless serials look like "host:port" — only those can be disconnected. */}
                            {d.serial.includes(':') && (
                                <button className="ghost-btn danger"
                                        disabled={busy === d.serial}
                                        onClick={() => disconnect(d.serial)}>
                                    {busy === d.serial ? '…' : t('adb.btnDisconnect')}
                                </button>
                            )}
                        </div>
                    ))}
                </div>
            </div>

            {/* ---- Result hint ---- */}
            {hint && (
                <div className="muted" style={{
                    padding: '8px 12px',
                    border: '1px solid var(--border)',
                    borderRadius: 8,
                    color: hintKind === 'err' ? 'var(--danger, #c0392b)' : undefined,
                    fontFamily: 'ui-monospace, Menlo, monospace',
                    whiteSpace: 'pre-wrap',
                }}>{hint}</div>
            )}
        </div>
    );
}
