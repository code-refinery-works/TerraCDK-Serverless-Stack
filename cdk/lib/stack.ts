import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as apigw from "aws-cdk-lib/aws-apigateway";
import * as iam from "aws-cdk-lib/aws-iam";
import * as ssm from "aws-cdk-lib/aws-ssm";
import * as logs from "aws-cdk-lib/aws-logs";
import * as path from "path";

interface Props extends cdk.StackProps {
  ssmPrefix: string;
  deployEnv: string;
  project: string;
}

export class ServerlessApiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: Props) {
    super(scope, id, props);

    const { ssmPrefix, deployEnv, project } = props;

    // ── Resolve Terraform outputs from SSM ──────────────────────────────────
    const tableName   = ssm.StringParameter.valueFromLookup(this, `${ssmPrefix}/dynamodb/table-name`);
    const lambdaRoleArn = ssm.StringParameter.valueFromLookup(this, `${ssmPrefix}/iam/lambda-role-arn`);
    const lambdaLogGroupName = ssm.StringParameter.valueFromLookup(this, `${ssmPrefix}/logs/lambda-log-group`);
    const apigwLogGroupName  = ssm.StringParameter.valueFromLookup(this, `${ssmPrefix}/logs/apigw-log-group`);

    // ── Reuse pre-provisioned IAM Role ───────────────────────────────────────
    const lambdaRole = iam.Role.fromRoleArn(this, "LambdaRole", lambdaRoleArn, {
      mutable: false,
    });

    // ── Reuse pre-provisioned Log Groups ────────────────────────────────────
    const lambdaLogGroup = logs.LogGroup.fromLogGroupName(this, "LambdaLogGroup", lambdaLogGroupName);
    const apigwLogGroup  = logs.LogGroup.fromLogGroupName(this, "ApigwLogGroup",  apigwLogGroupName);

    // ── Lambda Function ──────────────────────────────────────────────────────
    const handler = new lambda.Function(this, "Handler", {
      functionName: `${project}-${deployEnv}-handler`,
      runtime:      lambda.Runtime.NODEJS_20_X,
      handler:      "index.handler",
      code:         lambda.Code.fromAsset(path.join(__dirname, "../../src/lambda")),
      role:         lambdaRole,
      tracing:      lambda.Tracing.ACTIVE,
      logGroup:     lambdaLogGroup,
      environment: {
        TABLE_NAME: tableName,
        ENV:        deployEnv,
      },
      timeout:     cdk.Duration.seconds(29),
      memorySize:  256,
    });

    // ── API Gateway REST API ─────────────────────────────────────────────────
    const api = new apigw.RestApi(this, "Api", {
      restApiName:       `${project}-${deployEnv}`,
      endpointTypes:     [apigw.EndpointType.REGIONAL],
      deployOptions: {
        stageName:          deployEnv,
        tracingEnabled:     true,
        accessLogDestination: new apigw.LogGroupLogDestination(apigwLogGroup),
        accessLogFormat:    apigw.AccessLogFormat.jsonWithStandardFields(),
        loggingLevel:       apigw.MethodLoggingLevel.INFO,
        dataTraceEnabled:   false,
        metricsEnabled:     true,
      },
      defaultMethodOptions: {
        authorizationType: apigw.AuthorizationType.NONE, // swap to COGNITO/CUSTOM for prod
      },
      minCompressionSize: cdk.Size.bytes(1024),
      policy: new iam.PolicyDocument({
        statements: [new iam.PolicyStatement({
          effect:     iam.Effect.ALLOW,
          principals: [new iam.AnyPrincipal()],
          actions:    ["execute-api:Invoke"],
          resources:  ["execute-api:/*"],
        })],
      }),
    });

    // ── Request Validator ────────────────────────────────────────────────────
    const validator = new apigw.RequestValidator(this, "Validator", {
      restApi:                  api,
      validateRequestBody:      true,
      validateRequestParameters: true,
    });

    // ── Lambda Integration ───────────────────────────────────────────────────
    const integration = new apigw.LambdaIntegration(handler, { proxy: true });

    // /items  GET + POST
    const items = api.root.addResource("items");
    items.addMethod("GET",  integration, { requestValidator: validator });
    items.addMethod("POST", integration, { requestValidator: validator });

    // /items/{id}  GET + PUT + DELETE
    const item = items.addResource("{id}");
    item.addMethod("GET",    integration, { requestValidator: validator });
    item.addMethod("PUT",    integration, { requestValidator: validator });
    item.addMethod("DELETE", integration, { requestValidator: validator });

    // ── Outputs ──────────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, "ApiEndpoint", {
      value:       api.url,
      description: "REST API base URL",
    });
    new cdk.CfnOutput(this, "LambdaFunctionName", {
      value:       handler.functionName,
      description: "Lambda function name",
    });
  }
}