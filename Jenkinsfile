@Library("jenkins-shared-library@jenkins-shared-library-4.1.383") _
@Library('automation-infra-jsl@automation-infra-jsl-1.0.44') __

import com.cybereason.sensor.EndpointManager
import com.cybereason.sensor.VmsDeployParams
import com.cybereason.sensor.VmSizeType
import com.cybereason.sensor.VmsDestroyParams

CONSUL_URL = 'cr-consul-gcp.eng.cybereason.net:8500'
env.VAULT_URL = env.DEV_VAULT_ADDR
env.VAULT_TOKEN = env.DEV_VAULT_TOKEN

IRELEASE_BASE = 'https://jenkins-irelease.eng.cybereason.net:443'
IRELEASE_PERSONALIZER_JOB = 'personalization-build-integration'

PHOENIX_DISCOVERY_URL = 'https://sensor-discovery-service-dev-us-ashburn-1.cybereason.net'
PHOENIX_ORG_ID = 'TGRAMT1XDGPP35VV58FD3NS11H'
// TODO: move to Vault or Jenkins credential store when Credentials/Create permission is available
PHOENIX_AUTH_KEY = '3KZGZN5R1ZWY06NFGSD5XBFBSMJ4N5FQT8Q6V44XZ1EDNVF4BD2'

VM_USER = 'bbtest'
VM_PASS = 'Password1'
SSH_OPTS = '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o TCPKeepAlive=yes'

properties([
    parameters([
        string(name: 'VM_TEMPLATE', defaultValue: 'BB_Win11_x64_23H2_Performance',
               description: 'VMware template name for the test VM.'),
        booleanParam(name: 'ENABLE_PROFILING', defaultValue: true,
                     description: 'Enable ETL profiling (downloads ~1.1 GB PDBs, provides CPU hotspot analysis)'),
        booleanParam(name: 'HEAVY_MODE', defaultValue: false,
                     description: 'Run full workload suite (~3 hours). Default is light mode (~45 min).'),
        booleanParam(name: 'DESTROY_VM', defaultValue: true,
                     description: 'Destroy VM after test. Set to false to keep VM for debugging.'),
        booleanParam(name: 'SKIP_BOOTSTRAP', defaultValue: true,
                     description: 'Skip VM bootstrap (SSH, .NET, WPT install). Default template already has them.'),
        string(name: 'SENSOR_BRANCH', defaultValue: 'integration',
               description: 'Sensor branch name (e.g. integration, 24.2, 26.1). Maps to iRelease job msi-sensor-x64-release-build-{branch}.'),
        string(name: 'SENSOR_BUILD_NUMBER', defaultValue: '',
               description: 'Specific build number from iRelease. Leave empty for latest successful build.'),
        string(name: 'SENSOR_BUILD_URL', defaultValue: '',
               description: 'Full override URL to sensor build (ignores SENSOR_BRANCH/SENSOR_BUILD_NUMBER if set).'),
        string(name: 'ONLY_SCENARIOS', defaultValue: '',
               description: 'Comma-separated list of scenarios to run. Leave empty for all.'),
    ]),
    pipelineTriggers([cron('H 0 * * *')])
])

def label = "perf-nightly-${UUID.randomUUID().toString().substring(0,8)}"

podTemplate(
    cloud: 'gcp-sensor-automations',
    inheritFrom: 'jnlp',
    label: label,
    containers: [
        containerTemplate(name: 'python', image: 'python:3.11.6', ttyEnabled: true, command: 'cat'),
        containerTemplate(name: 'consul', image: 'hashicorp/consul:1.16', ttyEnabled: true, command: 'cat')
    ],
    volumes: [
        emptyDirVolume(mountPath: '/etc/data', memory: false)
    ]
) {
    node(label) {
        cleanWs()

        def endpointManager = new EndpointManager(this)
        String suiteRunId = UUID.randomUUID().toString().substring(0, 2)
        String envName = "pt-pri-${currentBuild.number}-${suiteRunId}"
        String vmIp = ''
        String sensorExeName = ''
        String rawExeName = ''
        boolean isVmDeployed = false

        String branchLabel = params.SENSOR_BRANCH ?: 'integration'
        currentBuild.displayName = "#${currentBuild.number} [${branchLabel}]"

        try {
            stage('Checkout') {
                checkout scm
            }

            stage('Download Sensor Artifacts') {
                container('python') {
                    sh """
                        apt-get update -qq && apt-get install -y -qq sshpass openssh-client osslsigncode > /dev/null 2>&1
                        ln -sf \$(which openssl) /usr/local/bin/openssl 2>/dev/null || true
                        ln -sf \$(which osslsigncode) /usr/local/bin/osslsigncode 2>/dev/null || true
                    """

                    withCredentials([
                        usernamePassword(credentialsId: 'rejenkins-gcp',
                                         usernameVariable: 'IRELEASE_USER',
                                         passwordVariable: 'IRELEASE_TOKEN')
                    ]) {
                        String ireleaseJob = "msi-sensor-x64-release-build-${params.SENSOR_BRANCH ?: 'integration'}"
                        String buildSelector = params.SENSOR_BUILD_NUMBER?.trim() ?
                            params.SENSOR_BUILD_NUMBER.trim() : 'lastSuccessfulBuild'
                        String buildApiUrl = params.SENSOR_BUILD_URL?.trim() ?:
                            "${IRELEASE_BASE}/job/${ireleaseJob}/${buildSelector}"
                        echo "Sensor source: ${buildApiUrl}"

                        sh """
                            mkdir -p sensor-artifacts

                            echo "Querying build info from: ${buildApiUrl}/api/json"
                            BUILD_JSON=\$(curl -sf -u "\${IRELEASE_USER}:\${IRELEASE_TOKEN}" "${buildApiUrl}/api/json")
                            BUILD_NUM=\$(echo "\$BUILD_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
                            echo "Build number: \$BUILD_NUM"

                            # Find sensor EXE artifact
                            SENSOR_EXE=\$(echo "\$BUILD_JSON" | python3 -c "
import sys, json
arts = json.load(sys.stdin)['artifacts']
for a in arts:
    if a['fileName'].startswith('CybereasonSensor64') and a['fileName'].endswith('.exe'):
                                print(a['relativePath'])
                                break
")
                            echo "Downloading sensor: \$SENSOR_EXE"
                            curl -sf -u "\${IRELEASE_USER}:\${IRELEASE_TOKEN}" \
                                "${buildApiUrl}/artifact/\${SENSOR_EXE}" \
                                -o "sensor-artifacts/\$(basename \$SENSOR_EXE)"

                            ls -lh sensor-artifacts/
                        """

                        if (params.ENABLE_PROFILING) {
                            sh """
                                echo "Looking for PDB archive..."
                                PDB_ZIP=\$(curl -sf -u "\${IRELEASE_USER}:\${IRELEASE_TOKEN}" "${buildApiUrl}/api/json" | \
                                    python3 -c "
import sys, json
arts = json.load(sys.stdin)['artifacts']
for a in arts:
    fn = a['fileName'].lower()
    if fn.endswith('.zip') and ('output' in fn or 'pdb' in fn or 'symbol' in fn):
        print(a['relativePath'])
        break
else:
    # List all artifacts for debugging
    print('NOT_FOUND', file=sys.stderr)
    for a in arts:
        print(f'  artifact: {a[\"fileName\"]} ({a[\"relativePath\"]})', file=sys.stderr)
")
                                if [ -n "\$PDB_ZIP" ]; then
                                    echo "Downloading PDB archive: \$PDB_ZIP"
                                    curl -sf -u "\${IRELEASE_USER}:\${IRELEASE_TOKEN}" \
                                        "${buildApiUrl}/artifact/\${PDB_ZIP}" \
                                        -o "sensor-artifacts/output-x64.zip" || {
                                        echo "[WARN] PDB download failed, profiling will have unresolved symbols"
                                    }
                                else
                                    echo "[WARN] No PDB archive found in build artifacts, profiling will have unresolved symbols"
                                fi
                                ls -lh sensor-artifacts/
                            """
                        }
                    }

                    rawExeName = sh(returnStdout: true, script:
                        "ls sensor-artifacts/CybereasonSensor64*.exe | head -1 | xargs basename"
                    ).trim()
                    echo "Raw sensor EXE: ${rawExeName}"

                    withCredentials([
                        usernamePassword(credentialsId: 'rejenkins-gcp',
                                         usernameVariable: 'IRELEASE_USER',
                                         passwordVariable: 'IRELEASE_TOKEN')
                    ]) {
                        sh """
                            echo "=== Downloading personalizer ==="
                            PERS_API="${IRELEASE_BASE}/job/${IRELEASE_PERSONALIZER_JOB}/lastSuccessfulBuild/api/json"
                            PERS_JSON=\$(curl -sf -u "\${IRELEASE_USER}:\${IRELEASE_TOKEN}" "\$PERS_API")
                            PERS_PATH=\$(echo "\$PERS_JSON" | python3 -c "
import sys, json
arts = json.load(sys.stdin)['artifacts']
for a in arts:
    if a['fileName'].startswith('personalizer') and a['fileName'].endswith('.gz'):
        print(a['relativePath']); break
")
                            PERS_URL="${IRELEASE_BASE}/job/${IRELEASE_PERSONALIZER_JOB}/lastSuccessfulBuild/artifact/\${PERS_PATH}"
                            echo "Downloading: \$PERS_URL"
                            curl -sf -u "\${IRELEASE_USER}:\${IRELEASE_TOKEN}" "\$PERS_URL" -o personalizer.tar.gz
                            ls -lh personalizer.tar.gz

                            echo "=== Extracting personalizer ==="
                            mkdir -p personalizer
                            tar -xzf personalizer.tar.gz -C personalizer
                            ls personalizer/
                        """
                    }

                    echo "=== Personalizing sensor EXE ==="
                    sh """
                        pip install protobuf --quiet 2>/dev/null

                        cat > personalizer/perf_personalization.json << 'PJSON'
{
    "msi_files": ["../sensor-artifacts/${rawExeName}"],
    "output_folder": "../sensor-artifacts/personalized/",
    "signon_server": "z-razor-r.eng.cybereason.net",
    "signon_port": "443",
    "server": "z-razor-1-t.eng.cybereason.net",
    "port": "443",
    "organization": "cybereason",
    "organizationId": "TGRAMT1XDGPP35VV58FD3NS11H",
    "state": "ACTIVE_NORMAL",
    "discoveryServerUrl": "${PHOENIX_DISCOVERY_URL}",
    "isOIDPersonalization": true
}
PJSON
                        mkdir -p sensor-artifacts/personalized
                        cd personalizer
                        PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python python3 personalizePackage.py -b perf_personalization.json
                        cd ..
                        ls -lh sensor-artifacts/personalized/
                    """

                    String persExeName = sh(returnStdout: true, script:
                        "ls sensor-artifacts/personalized/CybereasonSensor64*.exe 2>/dev/null | head -1 | xargs basename || echo ''"
                    ).trim()

                    if (!persExeName) {
                        error("Personalization failed -- no personalized EXE found in sensor-artifacts/personalized/")
                    }

                    sensorExeName = "CybereasonSensor64_personalized.exe"
                    sh "cp sensor-artifacts/personalized/${persExeName} sensor-artifacts/${sensorExeName}"
                    echo "Personalized sensor EXE: ${persExeName} -> ${sensorExeName}"
                    currentBuild.displayName = "#${currentBuild.number}:${persExeName.replaceAll('CybereasonSensor64_', '').replaceAll('.exe', '')}"
                }
            }

            stage('Deploy VM') {
                container('consul') {
                    echo "Deploying VM with template: ${params.VM_TEMPLATE}"
                    echo "Environment name: ${envName}"

                    VmsDeployParams vmsDeployParams = new VmsDeployParams.Builder()
                        .envName(envName)
                        .squad("Performance.Infra")
                        .template(params.VM_TEMPLATE)
                        .vc("ORACLE")
                        .vmSize(VmSizeType.LARGE)
                        .count(1)
                        .build()

                    endpointManager.deployVms(vmsDeployParams)
                    isVmDeployed = true

                    def endpoints = sh(returnStdout: true, script:
                        "consul kv get -http-addr=${CONSUL_URL} -recurse automation/organizations/${envName}/endpoints/"
                    ).trim()
                    echo "Endpoints data:\n${endpoints}"

                    vmIp = sh(returnStdout: true, script: """
                        consul kv get -http-addr=${CONSUL_URL} -recurse automation/organizations/${envName}/endpoints/ \
                        | grep 'public_ip' | head -1 | awk -F: '{print \$2}' | tr -d ' '
                    """).trim()

                    if (!vmIp) {
                        error("Failed to retrieve VM IP from Consul for ${envName}")
                    }
                    echo "VM IP: ${vmIp}"
                }
            }

            stage('Bootstrap VM') {
                if (params.SKIP_BOOTSTRAP) {
                    echo "Skipping bootstrap (SKIP_BOOTSTRAP=true) -- template already has SSH, .NET 8, WPT"
                    org.jenkinsci.plugins.pipeline.modeldefinition.Utils.markStageSkippedForConditional(STAGE_NAME)
                } else {
                    container('python') {
                        echo "Bootstrapping VM at ${vmIp} via WinRM..."
                        writeFile file: 'bootstrap-winrm.py', text: """
import winrm, sys
session = winrm.Session('http://${vmIp}:5985/wsman', auth=('${VM_USER}', '${VM_PASS}'), transport='ntlm')
def run(cmd, desc):
    print('  [%s]...' % desc)
    r = session.run_ps(cmd)
    if r.std_out: print(r.std_out.decode().strip())
    if r.std_err: print(r.std_err.decode().strip())
    if r.status_code != 0: print('  [WARN] %s exit code %d' % (desc, r.status_code))
    return r.status_code
run('Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0', 'Install OpenSSH')
run('Set-Service -Name sshd -StartupType Automatic', 'sshd auto-start')
run('Start-Service sshd', 'Start sshd')
run("New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -EA SilentlyContinue", 'Firewall rule')
run("New-ItemProperty -Path 'HKLM:\\\\SOFTWARE\\\\OpenSSH' -Name DefaultShell -Value 'C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe' -PropertyType String -Force", 'Default shell')
run('winget install Microsoft.DotNet.SDK.8 --accept-package-agreements --accept-source-agreements --silent', '.NET SDK 8')
run('ssh -V', 'Verify SSH')
run('dotnet --version', 'Verify .NET')
print('Bootstrap complete.')
"""
                        sh """
                            pip install pywinrm --quiet
                            python3 bootstrap-winrm.py
                        """

                        echo "Waiting for SSH to become available..."
                        sh """
                            for i in \$(seq 1 30); do
                                if sshpass -p '${VM_PASS}' ssh ${SSH_OPTS} \
                                    ${VM_USER}@${vmIp} 'echo SSH_OK' 2>/dev/null; then
                                    echo "SSH is ready."
                                    exit 0
                                fi
                                echo "  Attempt \$i/30 -- SSH not ready yet, retrying in 10s..."
                                sleep 10
                            done
                            echo "ERROR: SSH not available after 5 minutes"
                            exit 1
                        """
                    }
                }
            }

            stage('Install Sensor') {
                container('python') {
                    echo "Copying sensor artifacts to VM..."
                    sh """
                        sshpass -p '${VM_PASS}' scp ${SSH_OPTS} sensor-artifacts/${sensorExeName} \
                            ${VM_USER}@${vmIp}:C:/Temp/${sensorExeName}
                        sshpass -p '${VM_PASS}' scp ${SSH_OPTS} sensor-artifacts/${rawExeName} \
                            ${VM_USER}@${vmIp}:C:/Temp/${rawExeName}
                    """
                    echo "Copied both personalized (${sensorExeName}) and original (${rawExeName}) to C:\\Temp"

                    echo "Creating target directories and copying perf test framework to VM..."
                    sh """
                        sshpass -p '${VM_PASS}' ssh ${SSH_OPTS} ${VM_USER}@${vmIp} \
                            "powershell -Command \\"New-Item -ItemType Directory -Path C:\\\\sensor\\\\sensor-perf-testing, C:\\\\sensor\\\\pdbs, C:\\\\Temp, C:\\\\PerfTest\\\\reports, C:\\\\PerfTest\\\\logs -Force | Out-Null\\""
                        cd \$(pwd) && sshpass -p '${VM_PASS}' scp ${SSH_OPTS} -r \
                            Run-PerfTest.ps1 tools/ test-scenarios/ setup-telegraf/ \
                            ${VM_USER}@${vmIp}:C:/sensor/sensor-perf-testing/
                    """

                    if (params.ENABLE_PROFILING && fileExists('sensor-artifacts/output-x64.zip')) {
                        echo "Uploading PDB archive (1.2 GB) and extracting on VM..."
                        sh """
                            sshpass -p '${VM_PASS}' scp ${SSH_OPTS} sensor-artifacts/output-x64.zip \
                                ${VM_USER}@${vmIp}:C:/sensor/output-x64.zip
                            sshpass -p '${VM_PASS}' ssh ${SSH_OPTS} ${VM_USER}@${vmIp} \
                                "powershell -Command \\"Expand-Archive -Path C:\\\\sensor\\\\output-x64.zip -DestinationPath C:\\\\sensor\\\\pdbs -Force; Remove-Item C:\\\\sensor\\\\output-x64.zip -Force\\""
                        """
                    }

                    echo "Installing personalized sensor..."
                    sh """
                        sshpass -p '${VM_PASS}' scp ${SSH_OPTS} tools/Install-Sensor-Phoenix.ps1 \
                            ${VM_USER}@${vmIp}:C:/Temp/Install-Sensor-Phoenix.ps1
                        sshpass -p '${VM_PASS}' ssh ${SSH_OPTS} ${VM_USER}@${vmIp} \
                            "powershell -ExecutionPolicy Bypass -File C:\\Temp\\Install-Sensor-Phoenix.ps1 \
                                -SensorExePath C:\\Temp\\${sensorExeName} \
                                -DiscoveryServerUrl ${PHOENIX_DISCOVERY_URL} \
                                -OrganizationId ${PHOENIX_ORG_ID} \
                                -PhoenixAuthKey ${PHOENIX_AUTH_KEY}"
                    """
                }
            }

            stage('Run Perf Tests') {
                container('python') {
                    String profilingFlags = ''
                    if (params.ENABLE_PROFILING) {
                        profilingFlags = '-EnableProfiling -SymbolsDir C:\\sensor\\pdbs'
                    }
                    String modeFlag = params.HEAVY_MODE ? '-HeavyMode' : ''
                    String scenariosFlag = ''
                    if (params.ONLY_SCENARIOS?.trim()) {
                        scenariosFlag = "-OnlyScenarios @(${params.ONLY_SCENARIOS.split(',').collect { "'${it.trim()}'" }.join(',')})"
                    }

                    sh """
                        sshpass -p '${VM_PASS}' ssh ${SSH_OPTS} ${VM_USER}@${vmIp} \
                            "powershell -Command \\"if (-not (Test-Path C:\\\\sensor\\\\sensor-perf-testing\\\\Run-PerfTest.ps1)) { Write-Host 'ERROR: Run-PerfTest.ps1 not found at C:\\\\sensor\\\\sensor-perf-testing'; Get-ChildItem C:\\\\sensor -Recurse -Name | Select-Object -First 40; exit 1 } else { Write-Host 'OK: Run-PerfTest.ps1 found' }\\""
                    """

                    // Write a launcher script that runs the perf test and writes a completion marker
                    writeFile file: 'run-perf-wrapper.ps1', text: """
\$ErrorActionPreference = 'Continue'
\$logFile = 'C:\\PerfTest\\perf-output.log'
\$markerFile = 'C:\\PerfTest\\perf-done.marker'
Remove-Item \$markerFile -ErrorAction SilentlyContinue
try {
    & C:\\sensor\\sensor-perf-testing\\Run-PerfTest.ps1 -ReportsDir C:\\PerfTest\\reports ${modeFlag} ${profilingFlags} ${scenariosFlag} *>&1 | Tee-Object -FilePath \$logFile
    \$exitCode = if (\$LASTEXITCODE) { \$LASTEXITCODE } else { 0 }
} catch {
    \$_ | Out-File -Append \$logFile
    \$exitCode = 1
}
[string]\$exitCode | Set-Content -Path \$markerFile -NoNewline
"""
                    sh """
                        sshpass -p '${VM_PASS}' scp ${SSH_OPTS} run-perf-wrapper.ps1 ${VM_USER}@${vmIp}:C:/PerfTest/run-perf-wrapper.ps1
                    """

                    // Launch as scheduled task so it survives SSH disconnects
                    sh """
                        sshpass -p '${VM_PASS}' ssh ${SSH_OPTS} ${VM_USER}@${vmIp} \
                            "powershell -Command \\"\\
                            \\\$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -File C:\\\\PerfTest\\\\run-perf-wrapper.ps1';\\
                            \\\$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4);\\
                            Register-ScheduledTask -TaskName PerfTest -Action \\\$action -Settings \\\$settings -User SYSTEM -Force | Out-Null;\\
                            Start-ScheduledTask -TaskName PerfTest;\\
                            Write-Host 'Perf test launched as scheduled task PerfTest'\\""
                    """

                    // Poll for completion by checking marker file
                    timeout(time: params.HEAVY_MODE ? 5 : 2, unit: 'HOURS') {
                        waitUntil(initialRecurrencePeriod: 30000, maxRecurrencePeriod: 60000) {
                            def checkResult = sh(script: """
                                sshpass -p '${VM_PASS}' ssh ${SSH_OPTS} ${VM_USER}@${vmIp} \
                                    "powershell -Command \\"if (Test-Path C:\\\\PerfTest\\\\perf-done.marker) { Write-Host PERF_TEST_DONE; exit 0 } else { Write-Host PERF_TEST_RUNNING; exit 1 }\\""
                            """, returnStatus: true)
                            return checkResult == 0
                        }
                    }

                    // Stream the last part of the output log
                    sh """
                        sshpass -p '${VM_PASS}' ssh ${SSH_OPTS} ${VM_USER}@${vmIp} \
                            "powershell -Command \\"Get-Content C:\\\\PerfTest\\\\perf-output.log -Tail 200\\""
                    """
                    // Check exit code from marker
                    def perfExitCode = sh(script: """
                        sshpass -p '${VM_PASS}' ssh ${SSH_OPTS} ${VM_USER}@${vmIp} \
                            "powershell -Command \\"\\
                            \\\$c = Get-Content C:\\\\PerfTest\\\\perf-done.marker -Raw -ErrorAction SilentlyContinue;\\
                            if (\\\$c) { Write-Host \\\$c.Trim() } else { Write-Host 0 }\\""
                    """, returnStdout: true).trim()
                    echo "Perf test exit code: ${perfExitCode}"
                    if (perfExitCode != '0' && perfExitCode != '') {
                        currentBuild.result = 'UNSTABLE'
                        echo "WARNING: Perf test exited with code ${perfExitCode}, collecting partial results"
                    }
                }
            }

            stage('Collect Reports') {
                container('python') {
                    sh """
                        rm -rf reports logs
                        mkdir -p reports logs
                        sshpass -p '${VM_PASS}' scp ${SSH_OPTS} -r ${VM_USER}@${vmIp}:C:/PerfTest/reports/* reports/ || true
                        sshpass -p '${VM_PASS}' scp ${SSH_OPTS} -r ${VM_USER}@${vmIp}:C:/PerfTest/logs/* logs/ || true
                        sshpass -p '${VM_PASS}' scp ${SSH_OPTS} ${VM_USER}@${vmIp}:C:/PerfTest/perf-output.log logs/perf-console-output.log || true
                        echo "--- Reports collected ---"
                        ls -lh reports/ || true
                        ls -lh logs/ || true
                    """
                }

                archiveArtifacts artifacts: 'reports/**/*', allowEmptyArchive: true
                archiveArtifacts artifacts: 'logs/**/*', allowEmptyArchive: true

                def perfReports = findFiles(glob: 'reports/sensor-perf-report-*.html')
                if (perfReports) {
                    publishHTML(target: [
                        reportName: "Sensor Perf Report",
                        reportDir: 'reports',
                        reportFiles: perfReports.collect { it.name }.join(','),
                        keepAll: true,
                        alwaysLinkToLastBuild: true,
                        allowMissing: true
                    ])
                }

                def etlReports = findFiles(glob: 'reports/etl-cpu-hotspots-report-*.html')
                if (etlReports) {
                    publishHTML(target: [
                        reportName: "ETL CPU Hotspots",
                        reportDir: 'reports',
                        reportFiles: etlReports.collect { it.name }.join(','),
                        keepAll: true,
                        alwaysLinkToLastBuild: true,
                        allowMissing: true
                    ])
                }
            }

        } catch (Exception e) {
            currentBuild.result = 'FAILURE'
            echo "Pipeline failed: ${e.message}"
            throw e
        } finally {
            stage('Destroy VM') {
                if (isVmDeployed && params.DESTROY_VM) {
                    catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                        container('consul') {
                            VmsDestroyParams destroyParams = new VmsDestroyParams.Builder()
                                .envName(envName)
                                .squad("Performance.Infra")
                                .build()
                            endpointManager.destroy(destroyParams)
                            echo "VM destroyed successfully"
                        }
                    }
                } else if (!params.DESTROY_VM) {
                    echo "VM kept alive for debugging: ${vmIp} (env: ${envName})"
                    echo "Destroy manually: vms-destroy with organization=${envName}"
                }
            }
        }
    }
}
