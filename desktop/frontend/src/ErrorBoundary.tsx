// Catches render / lifecycle errors in a page subtree so one broken panel
// shows a readable error instead of unmounting the whole app to a white
// screen. React has no hook form of this — it must be a class component.
import {Component} from 'react';
import type {ErrorInfo, ReactNode} from 'react';

interface Props {
    children: ReactNode;
}

interface State {
    error: Error | null;
    componentStack: string;
}

export class ErrorBoundary extends Component<Props, State> {
    state: State = {error: null, componentStack: ''};

    static getDerivedStateFromError(error: Error): State {
        return {error, componentStack: ''};
    }

    componentDidCatch(error: Error, info: ErrorInfo) {
        this.setState({componentStack: info.componentStack || ''});
        // Surfaces in `wails dev` terminal and -debug builds.
        console.error('[ErrorBoundary] page crashed:', error, info.componentStack);
    }

    render() {
        const {error, componentStack} = this.state;
        if (!error) return this.props.children;
        return (
            <div style={{
                padding: 16,
                margin: 4,
                border: '1px solid var(--danger, #c0392b)',
                borderRadius: 8,
                fontFamily: 'ui-monospace, Menlo, monospace',
                fontSize: 12,
                color: 'var(--danger, #c0392b)',
                overflow: 'auto',
            }}>
                <div style={{fontWeight: 700, fontSize: 14, marginBottom: 8}}>
                    页面渲染出错 / Page crashed
                </div>
                <div style={{whiteSpace: 'pre-wrap', marginBottom: 8}}>
                    {String(error.stack || error)}
                </div>
                {componentStack && (
                    <details>
                        <summary style={{cursor: 'pointer'}}>component stack</summary>
                        <div style={{whiteSpace: 'pre-wrap'}}>{componentStack}</div>
                    </details>
                )}
            </div>
        );
    }
}
