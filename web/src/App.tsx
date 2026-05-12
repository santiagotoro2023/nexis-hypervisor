import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { useAuth, useSetupStatus } from './hooks/useAuth'
import { Login } from './components/layout/Login'
import { SetupWizard } from './components/setup/SetupWizard'
import { Dashboard } from './components/dashboard/Dashboard'
import { VMList } from './components/vms/VMList'
import { VMDetail } from './components/vms/VMDetail'
import { VMConsole } from './components/console/VMConsole'
import { ContainerList } from './components/containers/ContainerList'
import { ContainerDetail } from './components/containers/ContainerDetail'
import { ContainerShell } from './components/console/ContainerShell'
import { NodeShell } from './components/console/NodeShell'
import { Storage } from './components/storage/Storage'
import { Network } from './components/network/Network'
import { NexisController } from './components/nexis/NexisController'
import { SystemPage } from './components/system/SystemPage'
import { NxSpinner } from './components/common/NxSpinner'

function AppRoutes() {
  const { authed, loading, error, login } = useAuth()
  const { needsSetup, setupDone, checked, recheckSetup } = useSetupStatus()

  if (!checked) {
    return (
      <div className="min-h-screen bg-nx-bg flex items-center justify-center">
        <div className="text-center space-y-4">
          <NxSpinner size={32} />
          <div className="text-[10px] text-nx-fg2 tracking-widest uppercase">Initialising system...</div>
        </div>
      </div>
    )
  }

  if (needsSetup) {
    return <SetupWizard onComplete={recheckSetup} />
  }

  if (!authed) {
    return <Login onLogin={login} error={error} loading={loading} setupDone={setupDone} />
  }

  return (
    <Routes>
      <Route path="/" element={<Dashboard />} />
      <Route path="/vms" element={<VMList />} />
      <Route path="/vms/:id" element={<VMDetail />} />
      <Route path="/vms/:id/console" element={<VMConsole />} />
      <Route path="/containers" element={<ContainerList />} />
      <Route path="/containers/:id" element={<ContainerDetail />} />
      <Route path="/containers/:id/shell" element={<ContainerShell />} />
      <Route path="/nodes/:nodeId/shell" element={<NodeShell />} />
      <Route path="/storage" element={<Storage />} />
      <Route path="/network" element={<Network />} />
      <Route path="/nexis" element={<NexisController />} />
      <Route path="/system" element={<SystemPage />} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}

export default function App() {
  return (
    <BrowserRouter>
      <AppRoutes />
    </BrowserRouter>
  )
}
