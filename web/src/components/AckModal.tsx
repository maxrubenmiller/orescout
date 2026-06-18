import { useState } from 'react';

const ACK_VERSION = '1.0';
const K_ACCEPTED = 'orescout_ack_accepted';
const K_VERSION = 'orescout_ack_version';

function accepted(): boolean {
  try {
    return localStorage.getItem(K_ACCEPTED) === 'true'
      && localStorage.getItem(K_VERSION) === ACK_VERSION;
  } catch { return false; }
}

export default function AckModal() {
  const [done, setDone] = useState(accepted());
  if (done) return null;

  const accept = () => {
    try {
      localStorage.setItem(K_ACCEPTED, 'true');
      localStorage.setItem(K_VERSION, ACK_VERSION);
    } catch { /* ignore */ }
    setDone(true);
  };

  return (
    <div className="modal-backdrop">
      <div className="modal">
        <h2>Before you start</h2>
        <p>OreScout is a decision-support tool for hobbyist prospectors, rockhounds, and mineral
          collectors. By continuing you confirm that:</p>
        <ul>
          <li>You will not operate mechanized or motorized equipment (no suction dredges, excavators,
            bulldozers, or similar) based on guidance from this app.</li>
          <li>You will not conduct commercial mining or extraction based on data from this app.</li>
          <li>This app is not legal advice — you are responsible for verifying current land-use rules
            with the relevant managing agency before visiting any location.</li>
          <li>Data may be out of date. Land status, claims, and restrictions change. Always verify
            before you go.</li>
        </ul>
        <button className="btn primary" onClick={accept}>I understand — continue</button>
      </div>
    </div>
  );
}
