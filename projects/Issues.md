# Issues Faced During Implementation

## Infrastructure

### 1. Node Group Pod Capacity Issue

- **Problem**: While creating the node group via `t3.medium`, it worked initially as there was no monitoring and ArgoCD setup done initially. When the replicas of microservices app were increased, the error faced was "too many resources, too many pods, no new claims to deallocate".

- **Root Cause**: The `t3.medium` (specs: 2 vCPU, 4 GB RAM) instance type can only have the capacity of 17 pods. Since the default namespace already has pods and the replica count was 2 of each service, the "too many pods" error occurred.

- **Solution**: Upgraded the instance type to `t3.large` (specs: 2 vCPU, 8 GB RAM) which has a capacity of 35 pods.

### 2. EBS Volume Permission Issue

- **Problem**: While attaching the EBS volume, there was a permission issue.

- **Root Cause**: Kubernetes version greater than 1.32 in AWS EKS requires the IRSA (IAM Roles for Service Accounts) policy to be attached. IAM alone cannot handle the EBS attach to EKS.

- **Solution**: Configured IRSA policy for the EBS CSI driver.

---

## Database Issue

### 1. StatefulSet Init Script Failure

- **Problem**: Even though the StatefulSet was attached with an init script which had a DB dump in it, it was still failing to initialize. It was skipping the DB initializing resulting in "products page not found".

- **Root Cause**: The EBS has a folder by default named lost+found , so Postgres was considering that as the volume is not empty and it was skipping the initialisation resulting in the products pod running smoothly but when checking the logs, it was showing the product_db doesn't exist. 

- **Solution**: Created a DB-restore Job to add the DB. The correct step is to apply the DB-restore Job after the PostgreSQL pod is up and running.
- **Steps to Fix**:
  1. Wait for the PostgreSQL pod to be up and running
  2. Apply the DB-restore Job
  3. If the Job fails initially, delete the DB-restore Job and reapply it after the PostgreSQL pod is ready

---

## Monitoring

### 1. Boutique Application Metrics Not Found

- **Problem**: Even though the metrics of the cluster and node were obtained, the Boutique Application Metrics were not available. While running it via docker compose, it was showing the metrics properly. 

- **Root Cause**: The ServiceMonitor was configured with the path as `/metrics` but the application metrics were not being scraped properly.

- **Solution**: Added a ServiceMonitor with the correct path (`/metrics`) and updated the service file of the gateway so that the Grafana dashboard can have the data of the application with source as Prometheus.

---


Mistakes i did while doing it the first time
1)one question that whether it would be better if I had applied the restore job earlier?

Based on your project's architecture (specifically the `boutique-db-restore` job), the timing of when you apply that job is actually very important.

**Would it be better if you had applied it earlier?** **No, but with a catch.**

You **cannot** apply the restore job too early. If you apply the restore job *before* your PostgreSQL database pod is fully up and running, the restore job will instantly fail because it has no database to connect to.

However, you also don't want to apply it too late! If you wait too long, your backend microservices (like the Orders and Products services) will start up, try to read from the database, realize the tables don't exist yet, and start throwing errors or enter a `CrashLoopBackOff` state.

**The "Goldilocks" Timing:** The absolute best time to apply the DB Restore Job is **the exact moment the PostgreSQL pod becomes `Running` and `Ready`**, but before the rest of the microservices try to connect to it.

2)another question is that how were so many pods created that i had to start deleting at a time?

This happens because of a classic **cascading failure** in Kubernetes, mixed with how Kubernetes handles retries!

When you apply the restore job too early (or if it fails), it triggers a massive domino effect across your entire cluster. Here is exactly why your screen was suddenly flooded with dozens of pods:

**1. The Job Retry Loop (Backoff Limit)** Your `restore-job.yml` is configured as a Kubernetes `Job` with a `backoffLimit: 3`. When the job fails (because the database isn't ready), Kubernetes doesn't just give up. It aggressively tries to run it again. Every time it gives up on a pod, it leaves the old "Error" pod on your screen for you to inspect, and spins up a brand new one to try again.

**2. The Microservice "CrashLoopBackOff" Domino Effect** Because the database didn't restore properly, your database was completely empty. Your application has 5 separate backend microservices (*Auth, Gateway, Orders, Product, User*). When Kubernetes started all 5 of these services, they all instantly tried to connect to the database. They realized the tables didn't exist, threw a fatal error, and crashed.

**3. ArgoCD & ReplicaSets** Kubernetes is designed to be highly resilient. When a microservice crashes, Kubernetes says, *"Oh no! I need to keep this service alive!"* and immediately tries to restart it. This leads to the infamous `CrashLoopBackOff` state. If ArgoCD noticed any changes or you triggered a rolling update during this time, Kubernetes would try to spin up *even more* new pods to replace the crashing ones, while keeping the old ones around for a few minutes.

**The Result:** You ended up with:

- 4 failed Database Restore pods.
- 5 backend services multiplying into 10-15 crashing pods as Kubernetes frantically tried to keep them alive.
- All happening at the exact same time!

3)how to ensure so that it wont happen again in future when i run this project again?

When you tell Kubernetes to deploy an entire project at once, it tries to start *everything* simultaneously to be as fast as possible. The tutorial likely instructed you to apply the folder all at once, which is a flaw in the tutorial's design, not a mistake on your part!

To ensure this never happens again when you rebuild the project, you have two elegant, industry-standard ways to fix it:

### **1. The GitOps Way: ArgoCD Sync Waves (Recommended)**

Since you are using ArgoCD, it has a built-in feature called **Sync Waves**. You can add a single line of metadata to your files to tell ArgoCD exactly what order to deploy things in, and tell it to *wait* for each step to be completely healthy before moving on.

You would add these annotations to your YAML files:

- **Wave 1 (Database):** `argocd.argoproj.io/sync-wave: "1"`
- **Wave 2 (Restore Job):** `argocd.argoproj.io/sync-wave: "2"`
- **Wave 3 (Microservices):** `argocd.argoproj.io/sync-wave: "3"`

With this, ArgoCD deploys the database, waits until it's 100% running, *then* runs the restore job. It waits for the job to say "Success", and *then* finally deploys the microservices. Result? Zero crashing pods.

### **2. The Kubernetes Way: Init Containers**

If you weren't using ArgoCD, you would use an **Init Container**. This is a tiny, temporary container that runs *before* your main microservice.

You would add a 3-line script to your Backend microservices that basically does this:

while ! pg_isready -h boutique-postgres; do
    echo "Database not ready yet, sleeping..."
    sleep 2
done

This forces the microservice to pause and patiently wait. Once the database is online and the restore job is finished, the `while` loop breaks, and the microservice starts up peacefully.
