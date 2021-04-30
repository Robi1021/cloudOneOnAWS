#!/bin/bash
###eksctl scale nodegroup --cluster=managed-smartcheck --nodes=1 --name=<nodegroupName>
printf '%s\n' "-----------------"
printf '%s\n' "   Smart Check   "
printf '%s\n' "-----------------"


#Deploy Smartcheck
#------------------
HELM_DEPLOYMENTS=
if [[ "`helm list -n ${DSSC_NAMESPACE} -o json | jq -r '.[].name'`" =~ 'deepsecurity-smartcheck' ]];
  then
    printf '%s\n' "Reusing existing Smart Check deployment"
    cat cloudOneCredentials.txt
  else
    #get certificate for internal registry
    #-------------------------------------
    #create req.conf
    #printf '%s' "Creating req.conf..."
cat << EOF >./req.conf
# This file is (re-)generated by code.
# Any manual changes will be overwritten.
[req]
  distinguished_name=req
[san]
  subjectAltName=DNS:*.${AWS_REGION}.elb.amazonaws.com
EOF

    NAMESPACES=`kubectl get namespaces`
    if [[ "$NAMESPACES" =~ "${DSSC_NAMESPACE}" ]]; then
      printf '%s\n' "Reusing existing namespace \"${DSSC_NAMESPACE}\""
    else
      printf '%s' "Creating namespace smartcheck..."
      kubectl create namespace ${DSSC_NAMESPACE}
    fi

    printf '%s' "Creating certificate for loadballancer..."
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -keyout k8s.key -out k8s.crt -subj "/CN=*.${AWS_REGION}.elb.amazonaws.com" -extensions san -config req.conf

    printf '%s' "Creating secret with keys in Kubernetes..."
    kubectl create secret tls k8s-certificate --cert=k8s.crt --key=k8s.key --dry-run=true -n ${DSSC_NAMESPACE} -o yaml | kubectl apply -f -


    # Create overrides.yml
    #-------------------------
    printf '%s\n' "Creating overrides.yml file"

    cat << EOF >./overrides.yml
# This file is (re-) generated by code.
# Any manual changes will be overwritten.
#
##
## Default value: (none)
activationCode: '${DSSC_AC}'
auth:
  ## secretSeed is used as part of the password generation process for
  ## all auto-generated internal passwords, ensuring that each installation of
  ## Deep Security Smart Check has different passwords.
  ##
  ## Default value: {must be provided by the installer}
  secretSeed: 'just_anything-really_anything'
  ## userName is the name of the default administrator user that the system creates on startup.
  ## If a user with this name already exists, no action will be taken.
  ##
  ## Default value: administrator
  ## userName: administrator
  userName: '${DSSC_USERNAME}'
  ## password is the password assigned to the default administrator that the system creates on startup.
  ## If a user with the name 'auth.userName' already exists, no action will be taken.
  ##
  ## Default value: a generated password derived from the secretSeed and system details
  ## password: # autogenerated
  password: '${DSSC_TEMPPW}'
registry:
  ## Enable the built-in registry for pre-registry scanning.
  ##
  ## Default value: false
  enabled: true
    ## Authentication for the built-in registry
  auth:
    ## User name for authentication to the registry
    ##
    ## Default value: empty string
    username: '${DSSC_REGUSER}'
    ## Password for authentication to the registry
    ##
    ## Default value: empty string
    password: '${DSSC_REGPASSWORD}'
    ## The amount of space to request for the registry data volume
    ##
    ## Default value: 5Gi
  dataVolume:
    sizeLimit: 10Gi
certificate:
  secret:
    name: k8s-certificate
    certificate: tls.crt
    privateKey: tls.key
EOF

    printf '%s\n' "Deploying SmartCheck Helm chart... "
    helm install -n ${DSSC_NAMESPACE} --values overrides.yml deepsecurity-smartcheck https://github.com/deep-security/smartcheck-helm/archive/master.tar.gz > /dev/null
    #printf '%s\n' "Waiting for SmartCheck Service to come online"
    export DSSC_HOST=''
    while [[ "$DSSC_HOST" == '' ]];do
      export DSSC_HOST=`kubectl get svc -n ${DSSC_NAMESPACE} proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`
      sleep 10
    done
    #  echo SmartCheck URL will be https://${DSSC_HOST}
    #echo Username: $(kubectl get  secrets -o jsonpath='{ .data.userName }' deepsecurity-smartcheck-auth | base64 --decode)
    #echo Password: $(kubectl get  secrets -o jsonpath='{ .data.password }' deepsecurity-smartcheck-auth | base64 --decode)
    echo
    printf '%s' "Waiting for SmartCheck Service to come online: ."
    export DSSC_BEARERTOKEN=''
    while [[ "$DSSC_BEARERTOKEN" == '' ]];do
      sleep 10
      export DSSC_USERID=`curl -s -k -X POST https://${DSSC_HOST}/api/sessions -H "Content-Type: application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -d "{\"user\":{\"userid\":\"${DSSC_USERNAME}\",\"password\":\"${DSSC_TEMPPW}\"}}" | jq '.user.id'  2>/dev/null | tr -d '"' `
      #printf '%s' userid=$DSSC_USERID
      export DSSC_BEARERTOKEN=`curl -s -k -X POST https://${DSSC_HOST}/api/sessions -H "Content-Type: application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -d "{\"user\":{\"userid\":\"${DSSC_USERNAME}\",\"password\":\"${DSSC_TEMPPW}\"}}" | jq '.token' 2>/dev/null | tr -d '"'  `
      #printf '%s' Bearertoken=$DSSC_BEARERTOKEN
      printf '%s' "."
    done
    printf '%s \n' " "
    #printf '%s \n' "Bearer Token = ${DSSC_BEARERTOKEN} "
    #printf '%s \n' "DSSC_USERID  = ${DSSC_USERID} "

    #check certificate at loadbalancer
    #openssl s_client -showcerts -connect $DSSC_HOST:443

    #4.: do mandatory initial password change
    #----------------------------------------
    printf '%s \n' "Doing initial (required) password change"
    DUMMY=`curl -s -k -X POST https://${DSSC_HOST}/api/users/${DSSC_USERID}/password -H "Content-Type: application/json"  -H "Api-Version: 2018-05-01" -H "cache-control: no-cache" -H "authorization: Bearer ${DSSC_BEARERTOKEN}" -d "{  \"oldPassword\": \"${DSSC_TEMPPW}\", \"newPassword\": \"${DSSC_PASSWORD}\"  }"`

    printf '%s \n' "You can login: "
    printf '%s \n' "--------------"
    printf '%s \n' "     URL: https://${DSSC_HOST}"
    printf '%s \n' "     user: ${DSSC_USERNAME}"
    printf '%s \n' "     passw: ${DSSC_PASSWORD}"
    printf '%s \n' "--------------"

    #saving vars
    printf '%s \n' "export DSSC_HOST=${DSSC_HOST}" > cloudOneCredentials.txt
    printf '%s \n' "export DSSC_USERNAME=${DSSC_USERNAME}" >> cloudOneCredentials.txt
    printf '%s \n' "export DSSC_PASSWORD=${DSSC_PASSWORD}" >> cloudOneCredentials.txt

fi
