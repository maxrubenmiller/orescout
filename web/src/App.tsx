import { useUI } from './store';
import MapView from './components/MapView';
import LeftPanel from './components/LeftPanel';
import AssessmentPanel from './components/AssessmentPanel';
import SearchBar from './components/SearchBar';
import AckModal from './components/AckModal';

export default function App() {
  const toggleLeft = useUI((s) => s.toggleLeftPanel);
  return (
    <>
      <AckModal />
      <div className="app">
        <header className="topbar">
          <button className="icon-btn" onClick={toggleLeft} aria-label="Toggle panel">☰</button>
          <span className="brand">OreScout</span>
          <SearchBar />
        </header>
        <div className="stage">
          <LeftPanel />
          <MapView />
          <AssessmentPanel />
        </div>
      </div>
    </>
  );
}
