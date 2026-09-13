from types import SimpleNamespace

from kubernetes import client

from autonomous_sre.kube_actions import KubernetesExecutor
from autonomous_sre.models import RemediationPlan, Risk


class FakeAppsApi:
    def __init__(self, deployment, replica_sets):
        self.deployment = deployment
        self.replica_sets = replica_sets
        self.patch_body = None

    def read_namespaced_deployment(self, name, namespace):
        assert name == "demo-service"
        assert namespace == "demo"
        return self.deployment

    def list_namespaced_replica_set(self, namespace, label_selector):
        assert namespace == "demo"
        assert label_selector == "app=demo-service"
        return SimpleNamespace(items=self.replica_sets)

    def patch_namespaced_deployment(self, name, namespace, body):
        assert name == "demo-service"
        assert namespace == "demo"
        self.patch_body = body


def replica_set(uid: str, revision: int, error_rate: str):
    return client.V1ReplicaSet(
        metadata=client.V1ObjectMeta(
            name=f"demo-service-{revision}",
            annotations={"deployment.kubernetes.io/revision": str(revision)},
            owner_references=[
                client.V1OwnerReference(
                    api_version="apps/v1",
                    kind="Deployment",
                    name="demo-service",
                    uid=uid,
                )
            ],
        ),
        spec=client.V1ReplicaSetSpec(
            selector=client.V1LabelSelector(match_labels={"app": "demo-service"}),
            template=client.V1PodTemplateSpec(
                metadata=client.V1ObjectMeta(labels={"app": "demo-service"}),
                spec=client.V1PodSpec(
                    service_account_name="demo-service",
                    containers=[
                        client.V1Container(
                            name="demo-service",
                            image="example/demo:latest",
                            env=[client.V1EnvVar(name="ERROR_RATE", value=error_rate)],
                        )
                    ],
                ),
            ),
        ),
    )


def test_rollback_serializes_pod_template_with_kubernetes_json_field_names():
    deployment_uid = "deployment-uid"
    deployment = client.V1Deployment(
        metadata=client.V1ObjectMeta(name="demo-service", uid=deployment_uid),
        spec=client.V1DeploymentSpec(
            replicas=2,
            selector=client.V1LabelSelector(match_labels={"app": "demo-service"}),
            template=client.V1PodTemplateSpec(
                metadata=client.V1ObjectMeta(labels={"app": "demo-service"}),
                spec=client.V1PodSpec(
                    containers=[
                        client.V1Container(
                            name="demo-service",
                            image="example/demo:latest",
                        )
                    ]
                ),
            ),
        ),
    )
    current = replica_set(deployment_uid, 8, "0.85")
    previous = replica_set(deployment_uid, 7, "0")
    apps = FakeAppsApi(deployment, [previous, current])

    executor = KubernetesExecutor.__new__(KubernetesExecutor)
    executor.apps = apps
    executor.core = SimpleNamespace()
    plan = RemediationPlan(
        action="rollback_deployment",
        risk=Risk.MEDIUM,
        namespace="demo",
        target_kind="Deployment",
        target_name="demo-service",
    )

    result = executor._rollback_deployment(plan)

    assert result["from_revision"] == 8
    assert result["to_revision"] == 7
    template = apps.patch_body["spec"]["template"]
    assert template["spec"]["serviceAccountName"] == "demo-service"
    assert "service_account_name" not in template["spec"]
    env = template["spec"]["containers"][0]["env"]
    assert {item["name"]: item["value"] for item in env}["ERROR_RATE"] == "0"
    assert template["metadata"]["annotations"][
        "autonomous-sre/rollback-from-revision"
    ] == "8"
