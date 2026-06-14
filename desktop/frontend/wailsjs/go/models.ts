export namespace adbwireless {
	
	export class Device {
	    serial: string;
	    state: string;
	    product?: string;
	    model?: string;
	    device?: string;
	
	    static createFrom(source: any = {}) {
	        return new Device(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.serial = source["serial"];
	        this.state = source["state"];
	        this.product = source["product"];
	        this.model = source["model"];
	        this.device = source["device"];
	    }
	}
	export class Endpoint {
	    kind: string;
	    instance: string;
	    host: string;
	    port: number;
	    // Go type: time
	    seenAt: any;
	
	    static createFrom(source: any = {}) {
	        return new Endpoint(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.kind = source["kind"];
	        this.instance = source["instance"];
	        this.host = source["host"];
	        this.port = source["port"];
	        this.seenAt = this.convertValues(source["seenAt"], null);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class PairResult {
	    address: string;
	    raw: string;
	    guid?: string;
	
	    static createFrom(source: any = {}) {
	        return new PairResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.address = source["address"];
	        this.raw = source["raw"];
	        this.guid = source["guid"];
	    }
	}

}

export namespace snippets {
	
	export class Category {
	    id: number;
	    name: string;
	    prefix: string;
	    suffix: string;
	    defaultSendSuffix: string;
	    matchAppRegex: string;
	    sort: number;
	    // Go type: time
	    updatedAt: any;
	
	    static createFrom(source: any = {}) {
	        return new Category(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.prefix = source["prefix"];
	        this.suffix = source["suffix"];
	        this.defaultSendSuffix = source["defaultSendSuffix"];
	        this.matchAppRegex = source["matchAppRegex"];
	        this.sort = source["sort"];
	        this.updatedAt = this.convertValues(source["updatedAt"], null);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class DictionaryEntry {
	    id: number;
	    term: string;
	    sort: number;
	    // Go type: time
	    updatedAt: any;
	
	    static createFrom(source: any = {}) {
	        return new DictionaryEntry(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.term = source["term"];
	        this.sort = source["sort"];
	        this.updatedAt = this.convertValues(source["updatedAt"], null);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class Snippet {
	    id: number;
	    categoryId: number;
	    label: string;
	    content: string;
	    hotkey?: string;
	    sort: number;
	    // Go type: time
	    updatedAt: any;
	
	    static createFrom(source: any = {}) {
	        return new Snippet(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.categoryId = source["categoryId"];
	        this.label = source["label"];
	        this.content = source["content"];
	        this.hotkey = source["hotkey"];
	        this.sort = source["sort"];
	        this.updatedAt = this.convertValues(source["updatedAt"], null);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class Snapshot {
	    categories: Category[];
	    snippets: Snippet[];
	    dictionary: DictionaryEntry[];
	    revision: number;
	
	    static createFrom(source: any = {}) {
	        return new Snapshot(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.categories = this.convertValues(source["categories"], Category);
	        this.snippets = this.convertValues(source["snippets"], Snippet);
	        this.dictionary = this.convertValues(source["dictionary"], DictionaryEntry);
	        this.revision = source["revision"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

export namespace transport {
	
	export class PairingSnapshot {
	    state: string;
	    pin?: string;
	    // Go type: time
	    pinExpiresAt?: any;
	    deviceName?: string;
	    deviceId?: string;
	    // Go type: time
	    lockedUntil?: any;
	    failedAttempts?: number;
	
	    static createFrom(source: any = {}) {
	        return new PairingSnapshot(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.state = source["state"];
	        this.pin = source["pin"];
	        this.pinExpiresAt = this.convertValues(source["pinExpiresAt"], null);
	        this.deviceName = source["deviceName"];
	        this.deviceId = source["deviceId"];
	        this.lockedUntil = this.convertValues(source["lockedUntil"], null);
	        this.failedAttempts = source["failedAttempts"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class Status {
	    address: string;
	    port: number;
	    lanIps: string[];
	    connected: boolean;
	    authed: boolean;
	    connectedDevice?: string;
	    connectedDeviceId?: string;
	    // Go type: time
	    connectedAt?: any;
	
	    static createFrom(source: any = {}) {
	        return new Status(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.address = source["address"];
	        this.port = source["port"];
	        this.lanIps = source["lanIps"];
	        this.connected = source["connected"];
	        this.authed = source["authed"];
	        this.connectedDevice = source["connectedDevice"];
	        this.connectedDeviceId = source["connectedDeviceId"];
	        this.connectedAt = this.convertValues(source["connectedAt"], null);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

