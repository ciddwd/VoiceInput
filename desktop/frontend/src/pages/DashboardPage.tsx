import {useEffect, useState} from 'react';
import {t, useLocale} from '../i18n';
import {ForgetPairings, GetPairing, GetStatus} from '../../wailsjs/go/main/App';
import {EventsOn} from '../../wailsjs/runtime/runtime';

type Status = {
    address: string;
    port: number;
    lanIps: string[];
    connected: boolean;
    authed: boolean;
    connectedDevice?: string;
    connectedDeviceId?: string;
    connectedAt?: string;
};

type PairingSnapshot = {
    state: string;
    pin?: string;
    pinExpiresAt?: string;
    deviceName?: string;
    deviceId?: string;
    lockedUntil?: string;
    failedAttempts?: number;
};

type TextInput = { text: string; suffix?: string; mode?: string };
type FocusUpdate = { appName: string; processName: string; suggestedCategory?: string };
type LogEntry = { ts: number; kind: 'text' | 'clear' | 'focus' | 'system'; body: string };

function timestamp(ts: number): string {
    const d = new Date(ts);
    const pad = (n: number) => n.toString().padStart(2, '0');
    return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

export function DashboardPage() {
    useLocale();
    const [status, setStatus] = useState<Status | null>(null);
    const [pairing, setPairing] = useState<PairingSnapshot>({state: 'unpaired'});
    const [logs, setLogs] = useState<LogEntry[]>([]);
    const [focus, setFocus] = useState<FocusUpdate | null>(null);

    useEffect(() => {
        GetStatus().then(setStatus).catch(() => {});
        GetPairing().then(setPairing).catch(() => {});

        const offStatus = EventsOn('transport:status', (s: Status) => setStatus(s));
        const offPair = EventsOn('pairing:state', (p: PairingSnapshot) => setPairing(p));
        const offText = EventsOn('transport:text_input', (p: TextInput) => {
            const e: LogEntry = {ts: Date.now(), kind: 'text', body: p.text + (p.suffix ? ` [${p.suffix}]` : '')};
            setLogs((prev) => [e, ...prev].slice(0, 100));
        });
        const offClear = EventsOn('transport:text_clear', () => {
            const e: LogEntry = {ts: Date.now(), kind: 'clear', body: '(clear)'};
            setLogs((prev) => [e, ...prev].slice(0, 100));
        });
        const offFocus = EventsOn('focus:update', (f: FocusUpdate) => setFocus(f));
        return () => {
            offStatus(); offPair(); offText(); offClear(); offFocus();
        };
    }, []);

    const ip = status?.lanIps?.[0] ?? '127.0.0.1';
    const port = status?.port ?? 53118;

    const onForget = () => {
        if (!confirm(t('dash.confirmForget'))) return;
        ForgetPairings().catch(() => {});
    };

    return (
        <>
            {pairing.state === 'pinPending' && pairing.pin && (
                <PinModal pin={pairing.pin} deviceName={pairing.deviceName}/>
            )}
            <main className="grid">
                <section className="card">
                    <div className="card-header">
                        <span className="card-title">{t('dash.listening')}</span>
                        <span className={`pill ${connectionPillClass(status, pairing)}`}>
                            {connectionLabel(status, pairing)}
                        </span>
                    </div>
                    <div className="kv">
                        <div className="kv-row"><span className="kv-k">{t('dash.endpoint')}</span><code>ws://{ip}:{port}/ws</code></div>
                        <div className="kv-row"><span className="kv-k">{t('dash.lanIps')}</span>
                            <span>{(status?.lanIps ?? []).join(', ') || '—'}</span>
                        </div>
                        <div className="kv-row"><span className="kv-k">{t('dash.mdns')}</span>
                            <span><code>_voiceinput._tcp.local.</code></span>
                        </div>
                        <div className="kv-row"><span className="kv-k">{t('dash.device')}</span>
                            <span>{pairing.deviceName ?? status?.connectedDevice ?? '—'}</span>
                        </div>
                        <div className="kv-row"><span className="kv-k">{t('dash.foreground')}</span>
                            <span>{focus?.processName ?? '—'}
                                {focus?.suggestedCategory && (
                                    <span className="muted"> → {focus.suggestedCategory}</span>
                                )}
                            </span>
                        </div>
                    </div>
                    <div className="card-footer">
                        <button className="ghost-btn" onClick={onForget}>{t('dash.forgetDevices')}</button>
                    </div>
                </section>

                <section className="card card-wide">
                    <div className="card-header">
                        <span className="card-title">{t('dash.inbound')}</span>
                        <span className="muted">{logs.length === 1 ? t('dash.eventsOne') : t('dash.eventsMany', logs.length)}</span>
                    </div>
                    {logs.length === 0 ? (
                        <div className="empty">{t('dash.emptyLog')}</div>
                    ) : (
                        <ul className="log">
                            {logs.map((l, i) => (
                                <li key={i} className={`log-row log-${l.kind}`}>
                                    <span className="log-ts">{timestamp(l.ts)}</span>
                                    <span className="log-body">{l.body}</span>
                                </li>
                            ))}
                        </ul>
                    )}
                </section>
            </main>
        </>
    );
}

function connectionLabel(status: Status | null, pairing: PairingSnapshot): string {
    if (pairing.state === 'pinPending') return t('dash.pairing');
    if (pairing.state === 'locked') return t('dash.locked');
    if (!status?.connected) return t('dash.idle');
    if (!status.authed) return t('dash.awaitingAuth');
    return t('dash.connected');
}
function connectionPillClass(status: Status | null, pairing: PairingSnapshot): string {
    if (pairing.state === 'pinPending') return 'pill-warn';
    if (pairing.state === 'locked') return 'pill-bad';
    if (status?.authed) return 'pill-on';
    return 'pill-off';
}

function PinModal({pin, deviceName}: { pin: string; deviceName?: string }) {
    const grouped = pin.match(/.{1,3}/g)?.join(' ') ?? pin;
    return (
        <div className="modal-backdrop">
            <div className="modal">
                <div className="modal-title">{t('pair.title')}</div>
                <div className="modal-sub">
                    {deviceName ? <><b>{deviceName}</b>{t('pair.subPrefix')}</> : null}
                    {t('pair.subBody')}
                </div>
                <div className="pin-display">{grouped}</div>
                <div className="modal-foot muted">{t('pair.foot')}</div>
            </div>
        </div>
    );
}
