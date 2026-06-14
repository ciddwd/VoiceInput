import {useEffect, useRef, useState} from 'react';
import {t, useLocale} from '../i18n';
import {GetSnippets, ReplaceDictionary} from '../../wailsjs/go/main/App';
import {EventsOn} from '../../wailsjs/runtime/runtime';

type DictionaryEntry = { id: number; term: string; sort: number };

/**
 * Dictionary = the user's curated hotword list. Two consumers downstream:
 *   1. Polish provider — terms are injected into the system prompt as
 *      "preserve these verbatim", which keeps domain words from being
 *      "auto-corrected" by the LLM.
 *   2. Cloud ASR (later, Volcengine etc.) — terms get sent as
 *      context.hotwords so the recogniser knows to pick them.
 *
 * Stored on the desktop (alongside snippets), pushed to mobile via the
 * standard snippets/snapshot message.
 */
export function DictionaryPage() {
    useLocale();
    const [entries, setEntries] = useState<DictionaryEntry[]>([]);
    const [draft, setDraft] = useState('');
    const inputRef = useRef<HTMLInputElement>(null);
    const dirtyRef = useRef(false);

    useEffect(() => {
        GetSnippets().then((s: any) => setEntries(s?.dictionary ?? []));
        const off = EventsOn('snippets:changed', (s: any) => {
            if (!dirtyRef.current) setEntries(s?.dictionary ?? []);
        });
        return () => off();
    }, []);

    const persist = async (next: DictionaryEntry[]) => {
        dirtyRef.current = true;
        setEntries(next);
        try {
            await ReplaceDictionary(next.map((e) => e.term));
        } finally {
            dirtyRef.current = false;
        }
    };

    const addDraft = async () => {
        const v = draft.trim();
        if (!v) return;
        if (entries.some((e) => e.term === v)) {
            setDraft('');
            return;
        }
        const nextId = (entries[entries.length - 1]?.id ?? 0) + 1;
        const next: DictionaryEntry[] = [
            ...entries,
            {id: nextId, term: v, sort: entries.length},
        ];
        setDraft('');
        inputRef.current?.focus();
        await persist(next);
    };

    const remove = async (term: string) => {
        await persist(entries.filter((e) => e.term !== term));
    };

    const onKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
        if (e.key === 'Enter' || e.key === ',' || e.key === '、' || e.key === '，') {
            e.preventDefault();
            addDraft();
            return;
        }
        if (e.key === 'Backspace' && draft === '' && entries.length > 0) {
            remove(entries[entries.length - 1].term);
        }
    };

    return (
        <div className="dictionary-layout">
            <section className="card">
                <div className="card-header">
                    <span className="card-title">{t('dict.title')}</span>
                    <span className="muted">
                        {entries.length === 1 ? t('dict.subOne') : t('dict.subMany', entries.length)} {t('dict.subTail')}
                    </span>
                </div>

                <div className="chip-cloud">
                    {entries.map((e) => (
                        <span key={e.id} className="dict-chip">
                            {e.term}
                            <button className="dict-chip-x" onClick={() => remove(e.term)} title="Remove">×</button>
                        </span>
                    ))}
                    <input
                        ref={inputRef}
                        className="dict-input"
                        value={draft}
                        onChange={(e) => setDraft(e.target.value)}
                        onKeyDown={onKey}
                        onBlur={addDraft}
                        placeholder={entries.length === 0 ? t('dict.placeholderEmpty') : t('dict.placeholderMore')}
                        autoFocus/>
                </div>

                <div className="empty muted" style={{justifyContent: 'flex-start', textAlign: 'left', padding: '10px 0 0', lineHeight: 1.55}}>
                    <span>{t('dict.help')}</span>
                </div>
            </section>
        </div>
    );
}
