pipeline {
    agent any

    tools {
        maven 'maven'
        jdk 'JDK21'
    }

    environment {
        SONAR_HOST_URL = 'http://192.168.23.135:9000'
        REVISION       = "1.0-SNAPSHOT"
        MAVEN_REPO     = "/var/lib/jenkins/.m2/repository"
    }

    stages {

        // ───────────────── CHECKOUT ─────────────────
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        // ───────────────── GITLEAKS ─────────────────
        stage('Security Scan: Gitleaks') {
            steps {
                script {
                    sh 'git fetch origin main:refs/remotes/origin/main || true'

                    def scanRange = ''

                    if (env.BRANCH_NAME == 'main') {
                        scanRange = 'HEAD~1..HEAD'
                    } else {
                        def mainExists = sh(
                            script: 'git rev-parse --verify origin/main > /dev/null 2>&1',
                            returnStatus: true
                        )
                        scanRange = (mainExists == 0) ? 'origin/main..HEAD' : 'HEAD~1..HEAD'
                    }

                    echo "Scanning range: ${scanRange}"

                    def result = sh(
                        script: """
                            gitleaks detect \
                              --source=. \
                              --config=gitleaks.toml \
                              --log-opts="${scanRange}" \
                              --report-format=json \
                              --report-path=gitleaks-report.json \
                              --exit-code=1 \
                              --redact
                        """,
                        returnStatus: true
                    )

                    if (result == 0) {
                        echo "No secrets found"
                    } else {
                        def report = readFile('gitleaks-report.json')
                        echo report
                        error("Secrets detected in repository")
                    }
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'gitleaks-report.json', allowEmptyArchive: true
                }
            }
        }

        // ───────────────── PREPARE MAVEN ─────────────────
        stage('Prepare Maven') {
            steps {
                sh 'rm -rf ${MAVEN_REPO}/com/yas'
                sh '''
                    mvn install -N \
                        -DskipTests \
                        -Drevision=${REVISION} \
                        -Dmaven.repo.local=${MAVEN_REPO}
                '''
                sh '''
                    mvn flatten:flatten install \
                        -DskipTests \
                        -Drevision=${REVISION} \
                        -Dmaven.repo.local=${MAVEN_REPO} \
                        -f common-library/pom.xml
                '''
            }
        }

        // ───────────────── DETECT CHANGES ─────────────────
        stage('Detect Changes') {
            steps {
                script {
                    def changedFiles = ''

                    try {
                        changedFiles = sh(
                            script: "git diff --name-only HEAD~1 HEAD",
                            returnStdout: true
                        ).trim()
                    } catch (Exception e) {
                        changedFiles = sh(
                            script: "git diff --name-only origin/main...HEAD",
                            returnStdout: true
                        ).trim()
                    }

                    echo "Changed files:"
                    echo changedFiles

                    def services = [
                        'cart','customer','order','product','rating',
                        'inventory','media','tax','location','search'
                    ]

                    services.each { svc ->
                        env."${svc.toUpperCase()}_CHANGED" = changedFiles.contains("${svc}/") ? 'true' : 'false'
                    }

                    def statusLines = services.collect { svc ->
                        "| ${svc.padRight(10)} : ${env."${svc.toUpperCase()}_CHANGED"}"
                    }.join('\n')

                    echo """
+----------------------------------+
|        SERVICES TO BUILD         |
+----------------------------------+
${statusLines}
+----------------------------------+
"""
                }
            }
        }

        // ───────────────── BUILD SERVICES ─────────────────
        stage('Test & Build Services') {
            steps {
                script {
                    def services = [
                        'cart','customer','order','product','rating',
                        'inventory','media','tax','location','search'
                    ]

                    services.each { svc ->

                        if (env."${svc.toUpperCase()}_CHANGED" != 'true') {
                            echo "Skipping ${svc}"
                            return
                        }

                        echo "Building ${svc}"

                        def projectKey = "yas-${svc}"
                        def projectName = "YAS - ${svc.capitalize()}"

                        stage("${svc} Unit Test") {
                            sh "mvn clean test jacoco:report -pl ${svc} -am"
                            junit "${svc}/target/surefire-reports/*.xml"
                        }

                        stage("${svc} Coverage") {
                            recordCoverage(
                                tools: [[
                                    $class: 'CoverageTool',
                                    parser: 'JACOCO',
                                    pattern: "**/${svc}/target/site/jacoco/jacoco.xml"
                                ]],
                                sourceDirectories: [[path: "${svc}/src/main/java"]]
                            )
                        }

                        stage("${svc} SonarQube") {
                            withSonarQubeEnv('SonarQube') {
                                sh """
                                mvn sonar:sonar -pl ${svc} -am \
                                  -Dsonar.host.url=${SONAR_HOST_URL} \
                                  -Dsonar.projectKey=${projectKey} \
                                  -Dsonar.projectName="${projectName}" \
                                  -Dsonar.inclusions=${svc}/**/* \
                                  -Dsonar.coverage.jacoco.xmlReportPaths=${svc}/target/site/jacoco/jacoco.xml
                                """
                            }
                        }

                        stage("${svc} Quality Gate") {
                            timeout(time: 5, unit: 'MINUTES') {
                                waitForQualityGate abortPipeline: true
                            }
                        }

                        // ───── SNYK: chỉ chạy khi service thay đổi ─────
                        stage("${svc} Security Scan: Snyk") {
                            snykSecurity(
                                snykInstallation    : 'snyk',
                                snykTokenId         : 'snyk-token',
                                failOnIssues        : false,
                                monitorProjectOnBuild: false,
                                projectName         : projectKey,
                                targetFile          : "${svc}/pom.xml",
                                additionalArguments : '--severity-threshold=high'
                            )
                        }

                        stage("${svc} Build") {
                            sh "mvn package -pl ${svc} -am -DskipTests"
                        }
                    }
                }
            }
        }
    }

    post {
        always {
            cleanWs()
        }
        success {
            echo "✅ Pipeline completed successfully"
        }
        failure {
            echo "❌ Pipeline failed"
        }
    }
}
