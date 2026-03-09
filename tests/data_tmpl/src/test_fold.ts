import { getServers } from './global-setup';

export default async function globalTeardown() {
    const servers = getServers();
    for (const server of servers) {
        await server.stop();
    }
    console.log("All servers stopped");
}

function normalFunction(x: number): string {
    if (x > 0) {
        return String(x);
    }
    return "zero";
}

const arrowFn = (a: string, b: number) => {
    return a + b;
};
